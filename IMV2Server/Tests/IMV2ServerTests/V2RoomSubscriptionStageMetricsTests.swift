import Testing
@testable import IMV2ServerGateway

@Suite("Subscription stage metric boundaries")
struct V2RoomSubscriptionStageMetricsTests {
    @Test("overlapping foreground and repair stages settle independently")
    func overlappingStages() {
        let metrics = V2RoomSubscriptionHeadDeliveryMetrics()
        let start = ContinuousClock.now
        let first = metrics.begin(.subscribe, at: start)
        let second = metrics.begin(.subscribe, at: start + .seconds(1))
        let repair = metrics.begin(.subscribe, kind: .repair, at: start)
        metrics.finish(first, at: start + .seconds(2), outcome: .success)
        #expect(metrics.snapshot().phases[.foreground]?[.subscribe]?.active == 1)
        metrics.finish(second, at: start + .seconds(4), outcome: .outcomeUnknown)
        metrics.finish(repair, at: start + .seconds(5), outcome: .unavailable)
        let snapshot = metrics.snapshot()
        let value = snapshot.phases[.foreground]?[.subscribe]
        #expect(value?.active == 0)
        #expect(value?.completed == 2)
        #expect(value?.seconds == 5)
        #expect(value?.maximumSeconds == 3)
        #expect(value?.outcomes[.success] == 1)
        #expect(value?.outcomes[.outcomeUnknown] == 1)
        #expect(snapshot.phases[.repair]?[.subscribe]?.seconds == 5)
        let text = v2RenderPrometheusRoomSubscriptionHeadDeliveryMetrics(snapshot)
        #expect(text.contains("im_v2_room_subscription_acquisition_seconds_sum{kind=\"foreground\",phase=\"subscribe\"} 5.0"))
        #expect(text.contains("im_v2_room_subscription_acquisition_outcomes_total{kind=\"repair\",phase=\"subscribe\",outcome=\"unavailable\"} 1"))
    }
}

@Suite("Bounded passive coverage diagnostics")
struct V2GatewayCoverageDiagnosticTests {
    private func example(port: Int, request: UInt64) -> V2GatewayCoverageDiagnostics.Example {
        .init(sourcePort: port, requestID: request, clientTimeMilliseconds: 123,
            observedAtUnixMilliseconds: 124, generation: 5, lastAdmittedState: "recovering",
            pendingStates: [], writeInFlight: false, retryOwned: false,
            scopeRejectedRevision: nil,
            recovery: .init(current: true, generation: 5, demand: true, attempts: 0,
                placement: nil, installed: false, interestAcquired: true,
                currentCoverage: false, validCoverage: false, retainedReady: false,
                pendingRecovering: false, actualJob: false, outbound: false,
                requiredHead: nil, retainedHead: nil))
    }
    @Test("a repeated port replaces its witness and the fixed ring evicts old ports")
    func boundedWitnesses() {
        let examples = V2GatewayCoverageDiagnostics.Examples(capacity: 2)
        examples.record(example(port: 10001, request: 1))
        examples.record(example(port: 10002, request: 2))
        examples.record(example(port: 10001, request: 3))
        #expect(examples.snapshot().count == 2)
        #expect(examples.snapshot().first { $0.sourcePort == 10001 }?.requestID == 3)
        examples.record(example(port: 10003, request: 4))
        #expect(Set(examples.snapshot().map(\.sourcePort)) == [10002, 10003])
        let rendered = V2GatewayCoverageDiagnostics.render(examples.snapshot())
        #expect(rendered.split(separator: "\n").count == 2)
        #expect(rendered.split(separator: "\n").allSatisfy { $0.hasPrefix("# im_v2_account_coverage_wait_example ") })
        #expect(!rendered.contains("userID"))
        #expect(!rendered.contains("roomID"))
        #expect(!rendered.contains("physicalConnectionID"))
        #expect(V2GatewayCoverageDiagnostics.render([]).isEmpty)
        examples.remove(sourcePort: 10002)
        #expect(examples.snapshot().map(\.sourcePort) == [10003])
        examples.record(example(port: 10002, request: 5))
        #expect(examples.snapshot().count <= 2)
        let rooms = V2GatewayCoverageDiagnostics.ExampleStore<V2GatewayCoverageDiagnostics.RoomExample>(capacity: 1)
        rooms.record(.init(sourcePort: 10005, requestID: 7, clientTimeMilliseconds: 20,
            observedAtUnixMilliseconds: 21, requestedGeneration: 2, authorityGeneration: nil,
            absence: "no_interest", highWatermark: nil, socketReady: false,
            retainedHead: false, headWriterOwned: false, pendingStates: []))
        let roomText = V2GatewayCoverageDiagnostics.renderRooms(rooms.snapshot())
        #expect(roomText.hasPrefix("# im_v2_room_coverage_wait_example "))
        #expect(roomText.contains("no_interest"))
        rooms.remove(sourcePort: 10005)
        #expect(V2GatewayCoverageDiagnostics.renderRooms(rooms.snapshot()).isEmpty)

    }
}
