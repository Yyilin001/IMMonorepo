import Foundation
import IMV2Core
import Synchronization
import Testing
@testable import IMV2ClientKit

@Suite("Group avatar visible authorization", .timeLimit(.minutes(1)))
struct V2GroupAvatarPresentationRepositoryTests {
    @Test("a new denial, version or known-stale reply immediately notifies already visible consumers", arguments: ["denied", "version", "stale"])
    func visibleInvalidation(kind: String) async throws {
        let f = GroupPresentationFixture(), reader = ImmediateGroupPresentationReader(.success(try f.value()))
        let revision = GroupRevisionClock()
        let repo = f.repository(reader, minimum: { _ in revision.value }), first = try await repo.activate(roomID: f.room)
        let updates = try await repo.invalidations(for: first)
        var changes = updates.makeAsyncIterator()
        _ = try await repo.presentation(for: first)
        #expect(try await repo.cachedPresentation(for: first) != nil)
        await reader.respond(kind == "denied" ? .failure(V2GroupAvatarReadError.forbidden) : .success(try f.value(revision: 2)))
        if kind == "stale" { revision.set(3) }
        let otherPage = try await repo.activate(roomID: f.room)
        if kind == "denied" {
            await #expect(throws: V2GroupAvatarReadError.forbidden) { _ = try await repo.presentation(for: otherPage) }
        } else if kind == "stale" {
            await #expect(throws: V2GroupAvatarPresentationError.staleRevision) { _ = try await repo.presentation(for: otherPage) }
        } else { #expect(try await repo.presentation(for: otherPage).state.revision == 2) }
        #expect(await changes.next() != nil)
        #expect(try await repo.cachedPresentation(for: first) == nil)
        await repo.close()
        #expect(await changes.next() == nil)
    }

    @Test("concurrent consumers share one read, while page re-entry requires a new authorization")
    func sharedReadAndReentry() async throws {
        let f = GroupPresentationFixture(), reader = GroupPresentationGate(), repo = f.repository(reader)
        let first = try await repo.activate(roomID: f.room), second = try await repo.activate(roomID: f.room)
        let a = Task { try await repo.presentation(for: first) }, b = Task { try await repo.presentation(for: second) }
        try await waitConsumers(2, repo)
        try await reader.waitForCount(1)
        #expect(await reader.rooms.count == 1)
        let value = try f.value()
        await reader.finish(0, .success(value))
        #expect(try await a.value == value)
        #expect(try await b.value == value)
        #expect(try await repo.cachedPresentation(for: second) == value)
        await repo.deactivate(first)
        let next = try await repo.activate(roomID: f.room)
        #expect(try await repo.cachedPresentation(for: next) == nil)
        let c = Task { try await repo.presentation(for: next) }
        try await waitConsumers(1, repo)
        try await reader.waitForCount(2)
        #expect(await reader.rooms.count == 2)
        await reader.finish(1, .success(value))
        #expect(try await c.value == value)
        await repo.close()
    }

    @Test("cancelling one waiter leaves other consumers alive")
    func independentCancellation() async throws {
        let f = GroupPresentationFixture(), reader = GroupPresentationGate(), repo = f.repository(reader)
        let token = try await repo.activate(roomID: f.room)
        let first = Task { try await repo.presentation(for: token) }, second = Task { try await repo.presentation(for: token) }
        try await waitConsumers(2, repo)
        try await reader.waitForCount(1)
        first.cancel()
        await #expect(throws: CancellationError.self) { _ = try await first.value }
        #expect(await repo.diagnostics().waitingConsumers == 1)
        await reader.finish(0, .success(try f.value()))
        #expect(try await second.value.state.roomID == f.room)
        #expect(await reader.rooms.count == 1)
        await repo.close()
    }

    @Test("a cancelled noncooperative read cannot satisfy a new page or free an I/O slot early")
    func reentryDuringOldRead() async throws {
        let f = GroupPresentationFixture(), reader = GroupPresentationGate(), repo = f.repository(reader)
        let first = try await repo.activate(roomID: f.room)
        let old = Task { try await repo.presentation(for: first) }
        try await waitConsumers(1, repo)
        try await reader.waitForCount(1)
        await repo.deactivate(first)
        await #expect(throws: CancellationError.self) { _ = try await old.value }
        let next = try await repo.activate(roomID: f.room)
        let current = Task { try await repo.presentation(for: next) }
        try await waitConsumers(1, repo)
        #expect(await reader.rooms.count == 1)
        #expect(await repo.diagnostics().inFlight == 1)
        await reader.finish(0, .success(try f.value(revision: 1)))
        try await reader.waitForCount(2)
        #expect(try await repo.cachedPresentation(for: next) == nil)
        await reader.finish(1, .success(try f.value(revision: 2)))
        #expect(try await current.value.state.revision == 2)
        await repo.close()
    }

    @Test("at most two rooms perform I/O; queued work and activation admission are bounded")
    func boundedDemand() async throws {
        let f = GroupPresentationFixture(), reader = GroupPresentationGate(), repo = f.repository(reader)
        let rooms = (0..<4).map { _ in RoomID(uuid: UUID()) }
        var tokens: [V2GroupAvatarActivation] = [], tasks: [Task<V2GroupAvatarPresentation, Error>] = []
        for room in rooms {
            let token = try await repo.activate(roomID: room); tokens.append(token)
            tasks.append(Task { try await repo.presentation(for: token) })
        }
        try await waitConsumers(4, repo)
        try await reader.waitForCount(2)
        #expect(await reader.rooms.count == 2)
        #expect(await repo.diagnostics().inFlight == 2)
        for index in 0..<4 {
            try await reader.waitForCount(index + 1)
            let room = await reader.rooms[index]
            await reader.finish(index, .success(try f.value(room: room)))
        }
        for task in tasks { _ = try await task.value }
        for _ in 4..<256 { tokens.append(try await repo.activate(roomID: f.room)) }
        await #expect(throws: V2GroupAvatarPresentationError.overloaded) { _ = try await repo.activate(roomID: f.room) }
        #expect(await repo.diagnostics().activations == 256)
        await repo.endAllActivations()
        #expect(await repo.diagnostics().cachedBytes == 0)
        #expect(await repo.diagnostics().activations == 0)
        await repo.close()
    }

    @Test("a revision received during network I/O fences the response and a later cached lease")
    func revisionFences() async throws {
        let f = GroupPresentationFixture(), reader = GroupPresentationGate(), revision = GroupRevisionClock()
        let repo = f.repository(reader, minimum: { _ in revision.value })
        let token = try await repo.activate(roomID: f.room)
        let old = Task { try await repo.presentation(for: token) }
        try await waitConsumers(1, repo)
        try await reader.waitForCount(1)
        revision.set(3)
        await reader.finish(0, .success(try f.value(revision: 2)))
        await #expect(throws: V2GroupAvatarPresentationError.staleRevision) { _ = try await old.value }
        #expect(try await repo.cachedPresentation(for: token) == nil)
        let next = Task { try await repo.presentation(for: token) }
        try await waitConsumers(1, repo)
        try await reader.waitForCount(2)
        await reader.finish(1, .success(try f.value(revision: 3)))
        #expect(try await next.value.state.revision == 3)
        revision.set(4)
        #expect(try await repo.cachedPresentation(for: token) == nil)
        #expect(try await repo.authorizationDeadline(for: token) == nil)
        await repo.close()
    }

    @Test("context mismatches are rejected even through a non-HTTP reader", arguments: ["actor", "device", "room"])
    func contextBinding(field: String) async throws {
        let f = GroupPresentationFixture()
        let reader = ImmediateGroupPresentationReader(.success(try f.value(actor: field == "actor" ? .init(uuid: UUID()) : nil,
            device: field == "device" ? .init(uuid: UUID()) : nil, room: field == "room" ? .init(uuid: UUID()) : nil)))
        let repo = f.repository(reader), token = try await repo.activate(roomID: f.room)
        await #expect(throws: V2GroupAvatarPresentationError.invalidResponse) { _ = try await repo.presentation(for: token) }
        #expect(await repo.diagnostics().cachedRooms == 0)
        await repo.close()
    }

    @Test("monotonic display and byte deadlines subtract the whole round trip and ignore wall-clock skew")
    func deadlines() async throws {
        let f = GroupPresentationFixture(), reader = GroupPresentationGate(), clock = GroupMonotonicClock()
        let repo = f.repository(reader, now: { clock.now }), token = try await repo.activate(roomID: f.room)
        let request = Task { try await repo.presentation(for: token) }
        try await waitConsumers(1, repo)
        try await reader.waitForCount(1)
        clock.advance(20)
        // The server wall clock deliberately differs from the local wall clock.
        await reader.finish(0, .success(try f.value(avatar: true, serverNow: Date(timeIntervalSince1970: 1_000))))
        _ = try await request.value
        #expect(try await repo.avatarAccess(for: token) != nil)
        clock.advance(41)
        #expect(try await repo.avatarAccess(for: token) == nil)
        #expect(try await repo.cachedPresentation(for: token) != nil)
        clock.advance(240)
        #expect(try await repo.cachedPresentation(for: token) == nil)
        #expect(try await repo.authorizationDeadline(for: token) == nil)
        await repo.close()
    }

    @Test("only definite denials and server backoff are cached; invalidation clears them", arguments: [false, true])
    func denialAndTransient(forbidden: Bool) async throws {
        let f = GroupPresentationFixture(), failure: V2GroupAvatarReadError = forbidden ? .forbidden : .unavailable
        let reader = ImmediateGroupPresentationReader(.failure(failure)), repo = f.repository(reader)
        let token = try await repo.activate(roomID: f.room)
        for _ in 0..<2 { await #expect(throws: failure) { _ = try await repo.presentation(for: token) } }
        #expect(await reader.count == (forbidden ? 1 : 2))
        await repo.invalidate(roomID: f.room)
        await reader.respond(.success(try f.value()))
        #expect(try await repo.presentation(for: token).state.roomID == f.room)
        await repo.close()
    }

    @Test("backgrounding invalidates old activations and late reads before a new foreground activation")
    func epoch() async throws {
        let f = GroupPresentationFixture(), reader = GroupPresentationGate(), repo = f.repository(reader)
        let token = try await repo.activate(roomID: f.room), old = Task { try await repo.presentation(for: token) }
        try await waitConsumers(1, repo)
        try await reader.waitForCount(1)
        await repo.endAllActivations()
        await #expect(throws: V2GroupAvatarPresentationError.inactive) { _ = try await old.value }
        await #expect(throws: V2GroupAvatarPresentationError.inactive) { _ = try await repo.cachedPresentation(for: token) }
        let next = try await repo.activate(roomID: f.room), current = Task { try await repo.presentation(for: next) }
        try await waitConsumers(1, repo)
        await reader.finish(0, .success(try f.value(revision: 1)))
        try await reader.waitForCount(2)
        await reader.finish(1, .success(try f.value(revision: 2)))
        #expect(try await current.value.state.revision == 2)
        await repo.close()
        await #expect(throws: V2GroupAvatarPresentationError.inactive) { _ = try await repo.activate(roomID: f.room) }
    }

    private func waitConsumers(_ count: Int, _ repo: V2GroupAvatarPresentationRepository) async throws {
        let until = ContinuousClock.now.advanced(by: .seconds(5))
        while await repo.diagnostics().waitingConsumers != count {
            guard ContinuousClock.now < until else { throw GroupPresentationTestError.timeout }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

private struct GroupPresentationFixture {
    let actor = UserID(uuid: UUID()), device = DeviceID(uuid: UUID()), room = RoomID(uuid: UUID())
    func repository(_ reader: any V2GroupAvatarPresentationReading,
                    minimum: @escaping @Sendable (RoomID) async throws -> UInt64 = { _ in 0 },
                    now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) -> V2GroupAvatarPresentationRepository {
        .init(actorUserID: actor, deviceID: device, reader: reader, minimumRevision: minimum, now: now)
    }
    func value(revision: UInt64 = 1, actor: UserID? = nil, device: DeviceID? = nil, room: RoomID? = nil,
               avatar: Bool = false, serverNow: Date = Date()) throws -> V2GroupAvatarPresentation {
        let media = MediaID(uuid: UUID()), checksum = try V2ResourceChecksum(value: String(repeating: "a", count: 64))
        let access: V2ResourceAvatarAccess? = avatar ? try .init(mediaID: media, variantID: .init(uuid: UUID()), version: 1,
            checksum: checksum, plan: .init(mode: .httpGet, url: #require(URL(string: "https://delivery.invalid/avatar")),
                expiresAt: serverNow.addingTimeInterval(60), expectedByteCount: 1_000, checksum: checksum)) : nil
        return try .init(actorUserID: actor ?? self.actor, deviceID: device ?? self.device,
            state: .init(roomID: room ?? self.room, mediaID: avatar ? media : nil, revision: revision), membershipRevision: 1,
            resourceGeneration: avatar ? 1 : nil, canManage: false, avatar: access, observedAt: serverNow,
            validUntil: serverNow.addingTimeInterval(300), serverNow: serverNow)
    }
}

private enum GroupPresentationTestError: Error { case timeout }

/// Deliberately ignores cancellation, to exercise late-result and admission fences.
private actor GroupPresentationGate: V2GroupAvatarPresentationReading {
    var rooms: [RoomID] = []
    private var pending: [Int: CheckedContinuation<V2GroupAvatarPresentation, Error>] = [:]
    func readGroupAvatar(roomID: RoomID) async throws -> V2GroupAvatarPresentation {
        let index = rooms.count; rooms.append(roomID)
        return try await withCheckedThrowingContinuation { pending[index] = $0 }
    }
    func finish(_ index: Int, _ result: Result<V2GroupAvatarPresentation, Error>) { pending.removeValue(forKey: index)?.resume(with: result) }
    func waitForCount(_ count: Int) async throws {
        let until = ContinuousClock.now.advanced(by: .seconds(5))
        while rooms.count < count {
            guard ContinuousClock.now < until else { throw GroupPresentationTestError.timeout }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

private actor ImmediateGroupPresentationReader: V2GroupAvatarPresentationReading {
    var result: Result<V2GroupAvatarPresentation, Error>
    var count = 0
    init(_ result: Result<V2GroupAvatarPresentation, Error>) { self.result = result }
    func respond(_ result: Result<V2GroupAvatarPresentation, Error>) { self.result = result }
    func readGroupAvatar(roomID: RoomID) throws -> V2GroupAvatarPresentation { count += 1; return try result.get() }
}
private final class GroupRevisionClock: Sendable {
    private let current = Mutex<UInt64>(0)
    var value: UInt64 { current.withLock { $0 } }
    func set(_ value: UInt64) { current.withLock { $0 = value } }
}
private final class GroupMonotonicClock: Sendable {
    private let current = Mutex(ContinuousClock.now)
    var now: ContinuousClock.Instant { current.withLock { $0 } }
    func advance(_ seconds: Int) { current.withLock { $0 = $0.advanced(by: .seconds(seconds)) } }
}
