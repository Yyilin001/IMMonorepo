@testable import IMV2Server
import Testing

@Suite("V2 routed fan-out pipeline")
struct V2RoutedFanoutPipelineTests {
    @Test("independent owners progress concurrently and aggregate bounded work")
    func aggregatesIndependentOwners() async throws {
        let first = RoutedFanoutProgressor(
            relay: .success(.init(
                claimedCount: 2,
                publishedCount: 2,
                releasedCount: 0,
                pausedCount: 1
            )),
            delivery: .success(.init(
                claimedCount: 5,
                committedCount: 4,
                staleCount: 1,
                staleRouteCount: 0,
                releasedCount: 0,
                pausedCount: 2
            ))
        )
        let second = RoutedFanoutProgressor(
            relay: .success(.init(
                claimedCount: 3,
                publishedCount: 2,
                releasedCount: 1,
                pausedCount: 0
            )),
            delivery: .success(.init(
                claimedCount: 7,
                committedCount: 6,
                staleCount: 0,
                staleRouteCount: 1,
                releasedCount: 1,
                pausedCount: 0
            ))
        )
        let routed = try V2RoutedFanoutPipeline(progressors: [
            first,
            second,
        ])

        #expect(try await routed.runRelayAndPlanOnce(
            limit: 11,
            concurrencyPerOwner: 3
        ) == .init(
            claimedCount: 5,
            publishedCount: 4,
            releasedCount: 1,
            pausedCount: 1
        ))
        #expect(try await routed.runDeliveryOnce(
            claimLimit: 17,
            concurrencyPerOwner: 4
        ) == .init(
            claimedCount: 12,
            committedCount: 10,
            staleCount: 1,
            staleRouteCount: 1,
            releasedCount: 1,
            pausedCount: 2
        ))
        #expect(await first.relayArguments() == [.init(limit: 11, concurrency: 3)])
        #expect(await second.deliveryArguments() == [.init(limit: 17, concurrency: 4)])
    }

    @Test("one unavailable owner does not stop healthy owner recovery")
    func isolatesOneOwnerFailure() async throws {
        let failed = RoutedFanoutProgressor(
            relay: .failure(RoutedFanoutTestError.unavailable),
            delivery: .failure(RoutedFanoutTestError.unavailable)
        )
        let healthy = RoutedFanoutProgressor(
            relay: .success(.init(
                claimedCount: 1,
                publishedCount: 1,
                releasedCount: 0
            )),
            delivery: .success(.init(
                claimedCount: 2,
                committedCount: 2,
                staleCount: 0,
                releasedCount: 0
            ))
        )
        let routed = try V2RoutedFanoutPipeline(progressors: [failed, healthy])

        #expect(try await routed.runRelayAndPlanOnce(
            limit: 8,
            concurrencyPerOwner: 1
        ).publishedCount == 1)
        #expect(try await routed.runDeliveryOnce(
            claimLimit: 8,
            concurrencyPerOwner: 1
        ).committedCount == 2)
    }

    @Test("all unavailable owners surface a bounded aggregate failure")
    func failsWhenEveryOwnerIsUnavailable() async throws {
        let routed = try V2RoutedFanoutPipeline(progressors: [
            RoutedFanoutProgressor(
                relay: .failure(RoutedFanoutTestError.unavailable),
                delivery: .failure(RoutedFanoutTestError.unavailable)
            ),
            RoutedFanoutProgressor(
                relay: .failure(RoutedFanoutTestError.unavailable),
                delivery: .failure(RoutedFanoutTestError.unavailable)
            ),
        ])

        await #expect(throws: V2RoutedFanoutPipelineError.allOwnersFailed(2)) {
            try await routed.runRelayAndPlanOnce(
                limit: 8,
                concurrencyPerOwner: 1
            )
        }
    }

    @Test("completion release isolates one owner and aggregates healthy owners")
    func routesCompletionRelease() async throws {
        let worker = try V2RoutedFanoutCompletionReleaseWorker(progressors: [
            RoutedCompletionProgressor(
                result: .success(.init(releasedCount: 3, closedPlanCount: 1))
            ),
            RoutedCompletionProgressor(
                result: .failure(RoutedFanoutTestError.unavailable)
            ),
            RoutedCompletionProgressor(
                result: .success(.init(releasedCount: 2, closedPlanCount: 2))
            ),
        ])

        #expect(try await worker.runOnce(limitPerOwner: 19) == .init(
            releasedCount: 5,
            closedPlanCount: 3
        ))
    }
}

private struct RoutedFanoutArguments: Equatable, Sendable {
    let limit: Int
    let concurrency: Int
}

private actor RoutedFanoutProgressor: V2FanoutPipelineProgressing {
    private let relay: Result<V2OutboxRelayReport, RoutedFanoutTestError>
    private let delivery: Result<V2FanoutDeliveryReport, RoutedFanoutTestError>
    private var relays: [RoutedFanoutArguments] = []
    private var deliveries: [RoutedFanoutArguments] = []

    init(
        relay: Result<V2OutboxRelayReport, RoutedFanoutTestError>,
        delivery: Result<V2FanoutDeliveryReport, RoutedFanoutTestError>
    ) {
        self.relay = relay
        self.delivery = delivery
    }

    func runRelayAndPlanOnce(
        limit: Int,
        concurrency: Int
    ) throws -> V2OutboxRelayReport {
        relays.append(.init(limit: limit, concurrency: concurrency))
        return try relay.get()
    }

    func runDeliveryOnce(
        claimLimit: Int,
        concurrency: Int
    ) throws -> V2FanoutDeliveryReport {
        deliveries.append(.init(limit: claimLimit, concurrency: concurrency))
        return try delivery.get()
    }

    func relayArguments() -> [RoutedFanoutArguments] { relays }
    func deliveryArguments() -> [RoutedFanoutArguments] { deliveries }
}

private actor RoutedCompletionProgressor:
    V2FanoutCompletionReleaseProgressing {
    private let result: Result<
        V2FanoutCompletionReleaseReport,
        RoutedFanoutTestError
    >

    init(result: Result<
        V2FanoutCompletionReleaseReport,
        RoutedFanoutTestError
    >) {
        self.result = result
    }

    func runOnce(limit _: Int) throws
        -> V2FanoutCompletionReleaseReport {
        try result.get()
    }
}

private enum RoutedFanoutTestError: Error, Sendable {
    case unavailable
}
