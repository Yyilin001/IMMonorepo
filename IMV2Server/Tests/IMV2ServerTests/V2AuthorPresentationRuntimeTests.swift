@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing

@Suite("Author runtime dependency ownership", .timeLimit(.minutes(1)))
struct V2AuthorPresentationRuntimeTests {
    @Test("cancelled and concurrent closes drain actual work before closing the reader exactly once", arguments: ["read", "write"])
    func closeOrdering(heldPhase: String) async throws {
        let trace = Trace(holds: [heldPhase, "close"]), completed = Completed()
        let runtime = V2AuthorPresentationRuntime(configuration: try .init(mergeDelay: .zero),
            ingressConfiguration: try .init(), read: { request, _ in
                await trace.enter("read")
                return try .init(serverNowUnixMilliseconds: 1, results: request.keys.map { .unavailable($0) })
            }, closeReader: {
                #expect(!Task.isCancelled)
                await trace.enter("close")
            })
        let connection = UUID(), view = UUID(), room = RoomID(uuid: UUID())
        _ = try await runtime.dispatcher.register(connectionID: connection,
            identity: .init(userID: UserID(uuid: UUID()), deviceID: DeviceID(uuid: UUID()), capabilityProfile: "base"),
            send: { _, _ in await trace.enter("write"); return false })
        #expect(await runtime.dispatcher.activateView(connectionID: connection, roomID: room, viewID: view))
        #expect(runtime.ingress.submit(connectionID: connection, roomID: room, viewID: view, authors: [UserID(uuid: UUID())]))
        try await wait { await trace.waiting == heldPhase }
        let first = Task { await runtime.close(); await completed.finish() }
        first.cancel()
        let second = Task { await runtime.close(); await completed.finish() }
        try await wait { runtime.ingress.statistics().closed }
        #expect(await trace.events.contains("close.start") == false)
        #expect(await completed.count == 0)
        await trace.release()
        try await wait { await trace.waiting == "close" }
        #expect(await runtime.dispatcher.statistics().reading == 0)
        #expect(await runtime.dispatcher.statistics().writing == 0)
        #expect(await completed.count == 0)
        #expect(await trace.events.filter { $0 == "close.start" }.count == 1)
        await trace.release()
        await first.value; await second.value; await runtime.close()
        #expect(await completed.count == 2)
        let events = await trace.events
        #expect(events.last == "close.end")
        #expect(events.filter { $0 == "close.start" }.count == 1)
    }
}

private actor Completed { var count = 0; func finish() { count += 1 } }
private actor Trace {
    var holds: Set<String>
    var waiting: String?
    var continuation: CheckedContinuation<Void, Never>?
    var events: [String] = []
    init(holds: Set<String>) { self.holds = holds }
    func enter(_ phase: String) async {
        events.append(phase + ".start")
        if holds.remove(phase) != nil {
            waiting = phase
            await withCheckedContinuation { continuation = $0 }
        }
        events.append(phase + ".end")
    }
    func release() { waiting = nil; continuation?.resume(); continuation = nil }
}
private func wait(_ predicate: () async -> Bool) async throws {
    let end = ContinuousClock.now + .seconds(3)
    while !(await predicate()) { guard .now < end else { throw CancellationError() }; try await Task.sleep(for: .milliseconds(1)) }
}
