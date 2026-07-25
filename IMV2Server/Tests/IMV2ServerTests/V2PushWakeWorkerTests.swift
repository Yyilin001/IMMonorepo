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
