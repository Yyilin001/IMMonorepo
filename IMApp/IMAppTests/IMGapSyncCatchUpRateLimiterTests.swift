import Foundation
import Testing
@testable import IMApp

struct IMGapSyncCatchUpRateLimiterTests {
    @Test func timelineCatchUpProductionConfigurationMatchesCurrentDefaults() {
        let configuration = ConversationRuntimeController.TimelineCatchUpConfiguration.production

        #expect(configuration.selectedHintInitialJitterNanoseconds == 750_000_000)
        #expect(configuration.selectedHintMinimumIntervalNanoseconds == 750_000_000)
        #expect(configuration.selectedHintMicroBatchNanoseconds == 150_000_000)
    }

    @Test func timelineCatchUpConfigurationKeepsSelectedHintDelaysBounded() {
        let configuration = ConversationRuntimeController.TimelineCatchUpConfiguration(
            selectedHintInitialJitterNanoseconds: 0,
            selectedHintMinimumIntervalNanoseconds: 1,
            selectedHintMicroBatchNanoseconds: 1
        )

        #expect(configuration.selectedHintInitialJitterNanoseconds == 0)
        #expect(configuration.selectedHintMinimumIntervalNanoseconds == 10_000_000)
        #expect(configuration.selectedHintMicroBatchNanoseconds == 10_000_000)
    }

    @Test func runtimeTuningConfigurationUsesEnvironmentOverrides() {
        let suiteName = "runtime-tuning-env-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let configuration = AppRuntimeTuningConfiguration.timelineCatchUpConfiguration(
            defaults: defaults,
            environment: [
                AppRuntimeTuningConfiguration.selectedHintInitialJitterMillisecondsKey: "125",
                AppRuntimeTuningConfiguration.selectedHintMinimumIntervalMillisecondsKey: "250",
                AppRuntimeTuningConfiguration.selectedHintMicroBatchMillisecondsKey: "75"
            ]
        )
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        #expect(configuration.selectedHintInitialJitterNanoseconds == 125_000_000)
        #expect(configuration.selectedHintMinimumIntervalNanoseconds == 250_000_000)
        #expect(configuration.selectedHintMicroBatchNanoseconds == 75_000_000)
    }

    @Test func runtimeTuningConfigurationUsesUserDefaultsWhenEnvironmentIsUnset() {
        let suiteName = "runtime-tuning-defaults-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(300.0, forKey: AppRuntimeTuningConfiguration.selectedHintMinimumIntervalMillisecondsKey)
        defaults.set(50.0, forKey: AppRuntimeTuningConfiguration.selectedHintMicroBatchMillisecondsKey)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let configuration = AppRuntimeTuningConfiguration.timelineCatchUpConfiguration(
            defaults: defaults,
            environment: [:]
        )

        #expect(configuration.selectedHintInitialJitterNanoseconds == 750_000_000)
        #expect(configuration.selectedHintMinimumIntervalNanoseconds == 300_000_000)
        #expect(configuration.selectedHintMicroBatchNanoseconds == 50_000_000)
    }

    @Test func runtimeTuningConfigurationAllowsExplicitZeroUserDefaultsOverrides() {
        let suiteName = "runtime-tuning-zero-defaults-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(0.0, forKey: AppRuntimeTuningConfiguration.selectedHintInitialJitterMillisecondsKey)
        defaults.set(0.0, forKey: AppRuntimeTuningConfiguration.selectedHintMinimumIntervalMillisecondsKey)
        defaults.set(0.0, forKey: AppRuntimeTuningConfiguration.selectedHintMicroBatchMillisecondsKey)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let configuration = AppRuntimeTuningConfiguration.timelineCatchUpConfiguration(
            defaults: defaults,
            environment: [:]
        )

        #expect(configuration.selectedHintInitialJitterNanoseconds == 0)
        #expect(configuration.selectedHintMinimumIntervalNanoseconds == 10_000_000)
        #expect(configuration.selectedHintMicroBatchNanoseconds == 10_000_000)
    }

    @Test func dirtyMarkerIsConsumedOnce() {
        var limiter = IMGapSyncCatchUpRateLimiter(minimumIntervalNanoseconds: 750_000_000)
        let conversationID = "conversation-a"

        limiter.markDirty(conversationID)
        let firstConsume = limiter.consumeDirty(conversationID)
        let secondConsume = limiter.consumeDirty(conversationID)

        #expect(firstConsume)
        #expect(!secondConsume)
    }

    @Test func appliesMinimumIntervalAfterCompletedCatchUp() {
        var limiter = IMGapSyncCatchUpRateLimiter(minimumIntervalNanoseconds: 750_000_000)
        let conversationID = "conversation-a"
        let completedAt = Date(timeIntervalSince1970: 100)

        limiter.recordCompleted(for: conversationID, now: completedAt)
        limiter.applyRateLimitIfNeeded(
            for: conversationID,
            now: completedAt.addingTimeInterval(0.25)
        )

        let delayedUntil = limiter.delayUntil(
            for: conversationID,
            now: completedAt.addingTimeInterval(0.25)
        )
        #expect(delayedUntil == completedAt.addingTimeInterval(0.75))

        let expiredDelay = limiter.delayUntil(
            for: conversationID,
            now: completedAt.addingTimeInterval(0.80)
        )
        #expect(expiredDelay == nil)
    }

    @Test func deferredDirtyRunUsesConfiguredMinimumInterval() {
        var limiter = IMGapSyncCatchUpRateLimiter(minimumIntervalNanoseconds: 750_000_000)
        let conversationID = "conversation-a"
        let now = Date(timeIntervalSince1970: 100)

        limiter.deferNextRun(for: conversationID, now: now)

        let delayedUntil = limiter.delayUntil(
            for: conversationID,
            now: now.addingTimeInterval(0.10)
        )
        #expect(delayedUntil == now.addingTimeInterval(0.75))
    }

    @Test func clearingDelayRemovesPendingRateLimitOnlyForConversation() {
        var limiter = IMGapSyncCatchUpRateLimiter(minimumIntervalNanoseconds: 750_000_000)
        let firstConversationID = "conversation-a"
        let secondConversationID = "conversation-b"
        let now = Date(timeIntervalSince1970: 100)

        limiter.deferNextRun(for: firstConversationID, now: now)
        limiter.deferNextRun(for: secondConversationID, now: now)
        limiter.clearDelay(for: firstConversationID)

        #expect(limiter.delayUntil(for: firstConversationID, now: now) == nil)
        #expect(limiter.delayUntil(for: secondConversationID, now: now) == now.addingTimeInterval(0.75))
    }

    @Test func initialJitterUsesStableKeyAndDoesNotOverrideLongerDelay() {
        var limiter = IMGapSyncCatchUpRateLimiter(
            minimumIntervalNanoseconds: 750_000_000,
            initialJitterNanoseconds: 1_000_000_000
        )
        let conversationID = "conversation-a"
        let now = Date(timeIntervalSince1970: 100)

        limiter.applyInitialJitterIfNeeded(
            for: conversationID,
            stableKey: "user-a:conversation-a",
            now: now
        )
        let firstDelay = limiter.delayUntil(for: conversationID, now: now)
        guard let firstDelay else {
            Issue.record("Expected initial jitter to delay catch-up.")
            return
        }
        #expect(firstDelay >= now)
        #expect(firstDelay < now.addingTimeInterval(1))

        limiter.applyInitialJitterIfNeeded(
            for: conversationID,
            stableKey: "user-b:conversation-a",
            now: now
        )
        #expect(limiter.delayUntil(for: conversationID, now: now) == firstDelay)

        limiter.deferNextRun(for: conversationID, now: now)
        let minimumIntervalDelay = now.addingTimeInterval(0.75)
        let expectedDelay = firstDelay > minimumIntervalDelay ? firstDelay : minimumIntervalDelay
        #expect(limiter.delayUntil(for: conversationID, now: now) == expectedDelay)
    }

}
