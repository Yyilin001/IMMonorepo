import Foundation
import IMV2Core
import Testing
@testable import IMV2ServerApplication
@testable import IMV2ServerContracts

@Suite(.timeLimit(.minutes(1)))
struct V2AuthorPresentationContextTests {
    @Test("ACK and invalidation remain independent for the same user in different contexts")
    func contextIdentity() async throws {
        let probe = ContextProbe()
        let dispatcher = V2AuthorPresentationDispatcher(configuration: try .init(mergeDelay: .zero), readBatch: { try await probe.read($0) })
        let id = UUID(), stream = UUID(), view = UUID(), user = UserID(uuid: UUID())
        let a = RoomID(uuid: UUID()), b = RoomID(uuid: UUID())
        let keys: [V2ProfileViewLookupKey] = [.init(userID: user, context: .room(a)), .init(userID: user, context: .room(b)),
            .init(userID: user, context: .relationship), .init(userID: user, context: .groupJoinReview(a))]
        let identity = V2AuthenticatedConnection(userID: .init(uuid: UUID()), deviceID: .init(uuid: UUID()), capabilityProfile: "base")
        _ = try await dispatcher.register(connectionID: id, identity: identity, streamID: stream, send: { await probe.send($0, deadline: $1) })
        #expect(await dispatcher.activateView(connectionID: id, start: try .init(streamID: stream, viewID: view, messageRoomIDs: [])))
        #expect(await dispatcher.replaceVisibleInterests(connectionID: id, interests: try .init(streamID: stream, viewID: view, sequence: 1, keys: keys)))
        try await eventually { await dispatcher.statistics().deliveredFrames == 1 }
        let first = try #require(await probe.frames.first)
        #expect(Set(first.batch.results.map(\.key)) == Set(keys))
        await dispatcher.acknowledge(connectionID: id, receipt: try .init(streamID: stream, viewID: view, sequence: first.sequence,
            keys: [keys[0]], minimumRemainingMilliseconds: 0))
        await dispatcher.retryVisibleProfiles(at: .now + .seconds(2))
        try await eventually { await dispatcher.statistics().deliveredFrames == 2 }
        let second = try #require(await probe.frames.last)
        #expect(Set(second.batch.results.map(\.key)) == Set(keys.dropFirst()))
        await dispatcher.acknowledge(connectionID: id, receipt: try .init(streamID: stream, viewID: view, sequence: second.sequence,
            keys: Array(keys.dropFirst()), minimumRemainingMilliseconds: 0))
        await dispatcher.groupNicknameDidChange(try .init(roomID: a, userID: user, revision: 7))
        await dispatcher.retryVisibleProfiles()
        try await eventually { await dispatcher.statistics().deliveredFrames == 3 }
        #expect(await probe.frames.last?.batch.results.map(\.key) == [keys[0]])
        let third = try #require(await probe.frames.last)
        await dispatcher.acknowledge(connectionID: id, receipt: try .init(streamID: stream, viewID: view, sequence: third.sequence,
            keys: [keys[0]], minimumRemainingMilliseconds: 0))
        #expect(await dispatcher.replaceVisibleInterests(connectionID: id, interests: try .init(streamID: stream, viewID: view,
            sequence: 2, keys: Array(keys.dropFirst()))))
        #expect(await dispatcher.visibleSubscriptions(for: user).first?.keys == Set(keys.dropFirst()))
        await dispatcher.resetVisibleProfiles(roomID: a)
        await dispatcher.retryVisibleProfiles()
        try await eventually { await dispatcher.statistics().deliveredFrames == 4 }
        #expect(await probe.frames.last?.batch.results.map(\.key) == [keys[3]])
        #expect(await dispatcher.statistics().visibleInterests == 3)
        await dispatcher.close()
    }

    @Test("a resolved direct room remains indexed for permission changes")
    func directAuthorityRoomIsObserved() async throws {
        let user = UserID(uuid: UUID()), room = RoomID(uuid: UUID())
        let direct = V2ProfileViewLookupKey(userID: user, context: .directConversation)
        let relation = V2ProfileViewLookupKey(userID: user, context: .relationship)
        let probe = ContextProbe(authorityRooms: [direct: room])
        let dispatcher = V2AuthorPresentationDispatcher(configuration: try .init(mergeDelay: .zero), readBatch: { try await probe.read($0) })
        let id = UUID(), stream = UUID(), view = UUID()
        let identity = V2AuthenticatedConnection(userID: .init(uuid: UUID()), deviceID: .init(uuid: UUID()), capabilityProfile: "base")
        _ = try await dispatcher.register(connectionID: id, identity: identity, streamID: stream, send: { await probe.send($0, deadline: $1) })
        #expect(await dispatcher.activateView(connectionID: id, start: try .init(streamID: stream, viewID: view, messageRoomIDs: [])))
        #expect(await dispatcher.replaceVisibleInterests(connectionID: id, interests: try .init(streamID: stream, viewID: view, sequence: 1, keys: [direct, relation])))
        try await eventually { await dispatcher.statistics().deliveredFrames == 1 }
        let first = try #require(await probe.frames.first)
        await dispatcher.acknowledge(connectionID: id, receipt: try .init(streamID: stream, viewID: view, sequence: first.sequence,
            keys: [direct, relation], minimumRemainingMilliseconds: 0))
        await dispatcher.resetVisibleProfiles(roomID: room)
        await dispatcher.retryVisibleProfiles()
        try await eventually { await dispatcher.statistics().deliveredFrames == 2 }
        #expect(await probe.frames.last?.batch.results.map(\.key) == [direct])
        await dispatcher.close()
    }

    @Test("a list-only view partitions many room contexts without requiring a message room")
    func listWithoutMessageSubscription() async throws {
        let probe = ContextProbe()
        let dispatcher = V2AuthorPresentationDispatcher(configuration: try .init(mergeDelay: .zero), readBatch: { try await probe.read($0) })
        let id = UUID(), stream = UUID(), view = UUID(), user = UserID(uuid: UUID())
        let keys = (0..<24).map { _ in V2ProfileViewLookupKey(userID: user, context: .room(.init(uuid: UUID()))) }
        let identity = V2AuthenticatedConnection(userID: .init(uuid: UUID()), deviceID: .init(uuid: UUID()), capabilityProfile: "base")
        _ = try await dispatcher.register(connectionID: id, identity: identity, streamID: stream, send: { await probe.send($0, deadline: $1) })
        #expect(await dispatcher.activateView(connectionID: id, start: try .init(streamID: stream, viewID: view, messageRoomIDs: [])))
        #expect(await dispatcher.replaceVisibleInterests(connectionID: id, interests: try .init(streamID: stream, viewID: view, sequence: 1, keys: keys)))
        try await eventually { await probe.frames.reduce(0) { $0 + $1.batch.results.count } == 24 }
        let all = await probe.frames.flatMap { $0.batch.results.map(\.key) }
        #expect(Set(all) == Set(keys))
        #expect(all.count == keys.count)
        #expect(await probe.frames.count == 3)
        #expect(!(await dispatcher.offer(connectionID: id, roomID: try #require(keys[0].context.authorizationRoomID), authors: [user])))
        await dispatcher.close()
    }
}

private actor ContextProbe {
    let authorityRooms: [V2ProfileViewLookupKey: RoomID]
    init(authorityRooms: [V2ProfileViewLookupKey: RoomID] = [:]) { self.authorityRooms = authorityRooms }
    var frames: [V2AuthorPresentationDelta] = []
    func read(_ requests: [V2ProfilePresentationReadRequest]) throws -> [Result<V2ProfilePresentationBatchResponse, any Error>] {
        try requests.map { request in
            _ = try V2ProfilePresentationBatchRequest(keys: request.request.keys)
            return .success(try .init(serverNowUnixMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000),
                results: request.request.keys.map { key in
                    guard let room = authorityRooms[key] else { return .unavailable(key) }
                    return .unavailable(try .init(key: key, authorityVersion: .init(controlSequence: 0, roomID: room,
                        membershipRevision: 0, permissionRevision: 0)))
                }))
        }
    }
    func send(_ bytes: Data, deadline: ContinuousClock.Instant) -> V2AuthorPresentationWriteResult {
        guard let frame = try? V2AuthorPresentationDelta.decode(bytes) else { return .discarded }
        frames.append(frame); return .enqueued
    }
}

private func eventually(_ predicate: @escaping @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !(await predicate()) {
        guard ContinuousClock.now < deadline else { throw V2ResourceProviderError.configurationInvalid }
        try await Task.sleep(for: .milliseconds(1))
    }
}
