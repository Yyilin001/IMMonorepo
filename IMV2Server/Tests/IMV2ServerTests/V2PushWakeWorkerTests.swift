import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("V2 generic Push wake worker")
struct V2PushWakeWorkerTests {
    @Test("disabled campaign suppresses without touching the provider")
    func disabledCampaignSuppresses() async throws {
        let dispatchID = UUID()
        let device = try DeviceID("00000000-0000-0000-0000-000000000301")
        let campaign = try V2PushCampaignID(rawValue: "wake")
        let store = InMemoryV2PushWakeStore(seeds: [
            .init(
                wake: .init(dispatchID: dispatchID, deviceID: device, campaignID: campaign),
                campaignEnabled: false,
                request: .init(campaignID: campaign, requiresNewKeyOperation: false),
                budget: try .init(maxWorkUnits: 1, maxNewKeyOperations: 1)
            ),
        ])
        let provider = RecordingPushProvider()
        let report = try await V2PushWakeWorker(store: store, provider: provider).runOnce(limit: 1)

        #expect(report == .init(admittedCount: 0, sentCount: 0, releasedCount: 0))
        #expect(await provider.sentCount() == 0)
        #expect(await store.suppressionReason(for: dispatchID) == .campaignDisabled)
    }

    @Test("provider failure releases only Push work for retry")
    func providerFailureIsRetryable() async throws {
        let device = try DeviceID("00000000-0000-0000-0000-000000000302")
        let campaign = try V2PushCampaignID(rawValue: "wake")
        let store = InMemoryV2PushWakeStore(seeds: [
            .init(wake: .init(dispatchID: UUID(), deviceID: device, campaignID: campaign), campaignEnabled: true, request: .init(campaignID: campaign, requiresNewKeyOperation: false), budget: try .init(maxWorkUnits: 2, maxNewKeyOperations: 1)),
        ])
        let report = try await V2PushWakeWorker(store: store, provider: FailingPushProvider()).runOnce(limit: 1)
        #expect(report == .init(admittedCount: 1, sentCount: 0, releasedCount: 1))
    }

    @Test("provider endpoint rejection suppresses only the current wake")
    func rejectedEndpointIsTerminalForWake() async throws {
        let dispatchID = UUID()
        let device = try DeviceID("00000000-0000-0000-0000-000000000303")
        let campaign = try V2PushCampaignID(rawValue: "wake")
        let store = InMemoryV2PushWakeStore(seeds: [
            .init(wake: .init(dispatchID: dispatchID, deviceID: device, campaignID: campaign), campaignEnabled: true, request: .init(campaignID: campaign, requiresNewKeyOperation: false), budget: try .init(maxWorkUnits: 1, maxNewKeyOperations: 1)),
        ])

        let report = try await V2PushWakeWorker(store: store, provider: RejectingPushProvider()).runOnce(limit: 1)

        #expect(report == .init(admittedCount: 1, sentCount: 0, releasedCount: 0))
        #expect(await store.suppressionReason(for: dispatchID) == .endpointRejected)
    }

    @Test("provider sends use bounded concurrency")
    func providerConcurrencyIsBounded() async throws {
        let campaign = try V2PushCampaignID(rawValue: "wake")
        let seeds = try (0..<12).map { offset in
            V2PushDispatchSeed(
                wake: .init(
                    dispatchID: UUID(),
                    deviceID: try .init(String(format: "00000000-0000-0000-0000-%012d", 400 + offset)),
                    campaignID: campaign
                ),
                campaignEnabled: true,
                request: .init(campaignID: campaign, requiresNewKeyOperation: false),
                budget: try .init(maxWorkUnits: 1, maxNewKeyOperations: 1)
            )
        }
        let store = InMemoryV2PushWakeStore(seeds: seeds)
        let provider = ConcurrencyRecordingPushProvider()

        let report = try await V2PushWakeWorker(
            store: store,
            provider: provider,
            maximumConcurrency: 3
        ).runOnce(limit: seeds.count)

        #expect(report.sentCount == seeds.count)
        #expect(await provider.maximumObserved() == 3)
    }

    @Test("a non-cooperative provider is bounded and its durable lease is released")
    func providerTimeoutReleasesLease() async throws {
        let campaign = try V2PushCampaignID(rawValue: "wake")
        let store = InMemoryV2PushWakeStore(seeds: [
            .init(
                wake: .init(
                    dispatchID: UUID(),
                    deviceID: try .init("00000000-0000-0000-0000-000000000499"),
                    campaignID: campaign
                ),
                campaignEnabled: true,
                request: .init(campaignID: campaign, requiresNewKeyOperation: false),
                budget: try .init(maxWorkUnits: 1, maxNewKeyOperations: 1)
            ),
        ])
        let startedAt = Date()
        let report = try await V2PushWakeWorker(
            store: store,
            provider: HangingPushProvider(),
            leaseDuration: 1,
            sendTimeout: 0.02
        ).runOnce(limit: 1)

        #expect(report == .init(admittedCount: 1, sentCount: 0, releasedCount: 1))
        #expect(Date().timeIntervalSince(startedAt) < 1)
    }
}

private actor RecordingPushProvider: V2PushWakeProvider {
    private var count = 0
    func send(_: V2GenericPushWake) -> V2PushWakeProviderOutcome { count += 1; return .sent }
    func sentCount() -> Int { count }
}

private struct FailingPushProvider: V2PushWakeProvider {
    func send(_: V2GenericPushWake) throws -> V2PushWakeProviderOutcome { throw PushFailure.failed }
    private enum PushFailure: Error { case failed }
}

private struct RejectingPushProvider: V2PushWakeProvider {
    func send(_: V2GenericPushWake) -> V2PushWakeProviderOutcome { .suppressed(.endpointRejected) }
}

private actor ConcurrencyRecordingPushProvider: V2PushWakeProvider {
    private var active = 0
    private var maximum = 0

    func send(_: V2GenericPushWake) async throws -> V2PushWakeProviderOutcome {
        active += 1
        maximum = max(maximum, active)
        try await Task.sleep(for: .milliseconds(20))
        active -= 1
        return .sent
    }

    func maximumObserved() -> Int { maximum }
}

private struct HangingPushProvider: V2PushWakeProvider {
    func send(_: V2GenericPushWake) async throws -> V2PushWakeProviderOutcome {
        try await Task.sleep(for: .seconds(60))
        return .sent
    }
}
