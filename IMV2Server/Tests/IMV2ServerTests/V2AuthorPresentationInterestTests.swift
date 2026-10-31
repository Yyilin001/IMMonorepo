import Foundation
import IMV2Core
import Testing
@testable import IMV2ServerApplication
@testable import IMV2ServerContracts

@Suite(.timeLimit(.minutes(1)))
struct V2AuthorPresentationInterestTests {
    @Test("ten thousand subscriptions share one author index and close releases every watcher")
    func indexAtConnectionLimit() async throws {
        let dispatcher = V2AuthorPresentationDispatcher(configuration: try .init(), readBatch: { requests in
            requests.map { input in Result { try .init(serverNowUnixMilliseconds: 1,
                results: input.request.keys.map { .unavailable($0) }) } }
        })
        let author = UserID(uuid: UUID()), room = RoomID(uuid: UUID())
        let identity = V2AuthenticatedConnection(userID: .init(uuid: UUID()), deviceID: .init(uuid: UUID()), capabilityProfile: "standard")
        var subscriptions: [(UUID, UUID)] = []
        for _ in 0..<10_000 {
            let id = UUID(), view = UUID()
            let stream = try await dispatcher.registerFixture(connectionID: id, identity: identity, send: { bytes, _ in
                guard let delta = try? V2AuthorPresentationDelta.decode(bytes),
                      let receipt = try? V2AuthorPresentationReceipt(streamID: delta.streamID, viewID: delta.viewID,
                        sequence: delta.sequence, keys: delta.batch.results.map(\.key), minimumRemainingMilliseconds: 0) else { return false }
                // This test measures the watcher index. Acknowledge applied
                // denials so its clients do not also create a retry workload.
                await dispatcher.acknowledge(connectionID: id, receipt: receipt)
                return true
            })
            #expect(await dispatcher.activateRoomFixture(connectionID: id, roomID: room, viewID: view))
            #expect(await dispatcher.replaceVisibleInterests(connectionID: id, interests: try .init(
                streamID: stream, viewID: view, roomID: room, sequence: 1, userIDs: [author])))
            subscriptions.append((id, view))
        }
        #expect(await dispatcher.visibleSubscriptions(for: author).count == 10_000)
        #expect(await dispatcher.statistics().visibleInterests == 10_000)
        for (id, view) in subscriptions.prefix(100) { await dispatcher.deactivateView(connectionID: id, viewID: view) }
        #expect(await dispatcher.visibleSubscriptions(for: author).count == 9_900)
        await dispatcher.close()
        #expect(await dispatcher.statistics().visibleInterests == 0)
        #expect(await dispatcher.visibleSubscriptions(for: author).isEmpty)
    }
    @Test("visible replacement is ordered, page-bound and independent for each recipient")
    func replacement() async throws {
        let dispatcher = V2AuthorPresentationDispatcher(configuration: try .init(), readBatch: { requests in
            requests.map { input in Result { try .init(serverNowUnixMilliseconds: 1,
                results: input.request.keys.map { .unavailable($0) }) } }
        })
        let a = UUID(), b = UUID(), room = RoomID(uuid: UUID()), firstView = UUID(), secondView = UUID()
        let first = UserID(uuid: UUID()), second = UserID(uuid: UUID())
        let identity = V2AuthenticatedConnection(userID: .init(uuid: UUID()), deviceID: .init(uuid: UUID()), capabilityProfile: "standard")
        let streamA = try await dispatcher.registerFixture(connectionID: a, identity: identity, send: { _, _ in true })
        let streamB = try await dispatcher.registerFixture(connectionID: b, identity: identity, send: { _, _ in true })
        #expect(await dispatcher.activateRoomFixture(connectionID: a, roomID: room, viewID: firstView))
        #expect(await dispatcher.activateRoomFixture(connectionID: b, roomID: room, viewID: firstView))
        func interests(_ stream: UUID, view: UUID? = nil, sequence: UInt64, users: [UserID]) throws -> V2AuthorPresentationInterests {
            try .init(streamID: stream, viewID: view ?? firstView, roomID: room, sequence: sequence, userIDs: users)
        }
        #expect(await dispatcher.replaceVisibleInterests(connectionID: a, interests: try interests(streamA, sequence: 1, users: [first, second])))
        #expect(await dispatcher.replaceVisibleInterests(connectionID: b, interests: try interests(streamB, sequence: 1, users: [first])))
        #expect(await dispatcher.visibleSubscriptions(for: first).count == 2)
        #expect(await dispatcher.replaceVisibleInterests(connectionID: a, interests: try interests(streamA, sequence: 3, users: [second])))
        #expect(!(await dispatcher.replaceVisibleInterests(connectionID: a, interests: try interests(streamA, sequence: 2, users: [first]))))
        #expect(await dispatcher.visibleSubscriptions(for: first).map(\.connectionID) == [b])
        #expect(!(await dispatcher.replaceVisibleInterests(connectionID: a, interests: try interests(streamB, sequence: 4, users: [first]))))
        #expect(await dispatcher.activateRoomFixture(connectionID: a, roomID: room, viewID: secondView))
        #expect(await dispatcher.visibleSubscriptions(for: second).isEmpty)
        #expect(!(await dispatcher.replaceVisibleInterests(connectionID: a, interests: try interests(streamA, sequence: 5, users: [first]))))
        #expect(await dispatcher.replaceVisibleInterests(connectionID: a, interests: try interests(streamA, view: secondView, sequence: 1, users: [second])))
        #expect(await dispatcher.replaceVisibleInterests(connectionID: b, interests: try interests(streamB, sequence: 2, users: [])))
        #expect(await dispatcher.visibleSubscriptions(for: first).isEmpty)
        await dispatcher.unregister(connectionID: a)
        #expect(await dispatcher.statistics().visibleInterests == 0)
        await dispatcher.close()
    }
}
