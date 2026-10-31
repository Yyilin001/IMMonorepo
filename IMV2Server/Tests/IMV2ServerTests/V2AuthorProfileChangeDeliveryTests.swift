import Foundation
import IMV2Core
import Testing
@testable import IMV2ServerApplication
@testable import IMV2ServerContracts

@Suite(.timeLimit(.minutes(1)))
struct V2AuthorProfileChangeDeliveryTests {
    @Test("room authority repairs refresh only that room and retire reads captured before the repair")
    func roomResetScope() async throws {
        let probe = ChangeProbe()
        let dispatcher = V2AuthorPresentationDispatcher(configuration: try .init(mergeDelay: .zero),
            read: { request, identity in try await probe.read(request, identity: identity) })
        let first = ChangeFixture(dispatcher: dispatcher, probe: probe)
        let other = ChangeFixture(dispatcher: dispatcher, probe: probe, author: first.author)
        try await other.subscribe(); try await other.waitForFrames(1); try await other.acknowledge(0)
        await probe.holdNextRead()
        try await first.subscribe()
        try await changeWait { await probe.readWaiting }
        await dispatcher.resetVisibleProfiles(roomID: first.room)
        await probe.releaseRead(); try await first.waitForIdle()
        // Releasing the retired read now admits its replacement immediately.
        try await first.waitForFrames(2)
        #expect(try await probe.delta(1).roomID == first.room)
        try await first.acknowledge(1)
        #expect(await probe.reads == 3)
        await dispatcher.deactivateView(connectionID: first.connection, viewID: first.view)
        await dispatcher.resetVisibleProfiles(roomID: first.room)
        await dispatcher.retryVisibleProfiles(at: .now + .seconds(2))
        #expect(await probe.reads == 3)
        await dispatcher.unregister(connectionID: other.connection)
        await dispatcher.resetVisibleProfiles(roomID: other.room)
        #expect(await dispatcher.statistics().pendingKeys == 0)
        await dispatcher.close()
    }

    @Test("nickname changes refresh all visible recipients in that room and preserve a cleared nickname revision")
    func nicknameRoomScope() async throws {
        let probe = ChangeProbe(), room = RoomID(uuid: UUID()), author = UserID(uuid: UUID())
        try await probe.setNickname(room: room, author: author, revision: 1)
        let dispatcher = V2AuthorPresentationDispatcher(configuration: try .init(mergeDelay: .zero),
            read: { request, identity in try await probe.read(request, identity: identity) })
        let first = ChangeFixture(dispatcher: dispatcher, probe: probe, author: author, room: room)
        let second = ChangeFixture(dispatcher: dispatcher, probe: probe, author: author, room: room)
        let otherRoom = ChangeFixture(dispatcher: dispatcher, probe: probe, author: author)
        let otherAuthor = ChangeFixture(dispatcher: dispatcher, probe: probe, room: room)
        for (index, page) in [first, second, otherRoom, otherAuthor].enumerated() {
            try await page.subscribe(); try await page.waitForFrames(index + 1); try await page.acknowledge(index)
        }
        try await probe.setNickname(room: room, author: author, revision: 2, name: nil)
        let change = try V2AuthorGroupNicknameChange(roomID: room, userID: author, revision: 2)
        await dispatcher.groupNicknameDidChange(change)
        await dispatcher.retryVisibleProfiles()
        try await first.waitForFrames(6)
        var viewers = Set<UserID>()
        for index in 4..<6 {
            let delta = try await probe.delta(index)
            #expect(delta.roomID == room)
            viewers.insert(delta.actorUserID)
            guard case .presentation(let value, _) = delta.batch.results[0] else { throw CancellationError() }
            #expect(value.groupMember?.revision.rawValue == 2 && value.groupMember?.groupNickname == nil)
            try await (delta.actorUserID == first.actor ? first : second).acknowledge(index)
        }
        #expect(viewers == Set([first.actor, second.actor]))
        await dispatcher.groupNicknameDidChange(change)
        await dispatcher.retryVisibleProfiles(at: .now + .seconds(2))
        #expect(await probe.reads == 6)
        await dispatcher.close()
    }

    @Test("a nickname change retires in-flight data and its floor survives a later public change")
    func nicknameInitialRace() async throws {
        let f = try ChangeFixture()
        try await f.probe.setNickname(room: f.room, author: f.author, revision: 1)
        await f.probe.holdNextRead()
        try await f.subscribe()
        try await changeWait { await f.probe.readWaiting }
        await f.dispatcher.groupNicknameDidChange(try .init(roomID: f.room, userID: f.author, revision: 2))
        await f.probe.setRevision(2)
        await f.dispatcher.profileDidChange(try f.change(2))
        await f.probe.releaseRead(); try await f.waitForIdle()
        #expect(await f.probe.frames.isEmpty)
        await f.dispatcher.retryVisibleProfiles()
        try await changeWait { await f.probe.reads == 2 }
        try await f.waitForIdle()
        #expect(await f.probe.frames.isEmpty)
        try await f.probe.setNickname(room: f.room, author: f.author, revision: 2)
        await f.dispatcher.retryVisibleProfiles(at: .now + .seconds(2))
        try await f.waitForFrames(1)
        let delta = try await f.probe.delta(0)
        guard case .presentation(let value, _) = delta.batch.results[0] else { throw CancellationError() }
        #expect(value.view.revision.rawValue == 2 && value.groupMember?.revision.rawValue == 2)
        await f.dispatcher.close()
    }

    @Test("private alias changes refresh only the owner's devices across visible contexts")
    func privateAliasTargets() async throws {
        let probe = ChangeProbe(), owner = UserID(uuid: UUID()), target = UserID(uuid: UUID())
        await probe.setAlias(owner: owner, revision: 1)
        let dispatcher = V2AuthorPresentationDispatcher(configuration: try .init(mergeDelay: .zero),
            read: { request, identity in try await probe.read(request, identity: identity) })
        let first = ChangeFixture(dispatcher: dispatcher, probe: probe, actor: owner, author: target)
        let second = ChangeFixture(dispatcher: dispatcher, probe: probe, actor: owner, author: target)
        let targetPage = ChangeFixture(dispatcher: dispatcher, probe: probe, actor: target, author: owner)
        let other = ChangeFixture(dispatcher: dispatcher, probe: probe, author: target)
        for (index, page) in [first, second, targetPage, other].enumerated() {
            try await page.subscribe(); try await page.waitForFrames(index + 1); try await page.acknowledge(index)
        }
        await probe.setAlias(owner: owner, revision: 2, name: nil)
        await dispatcher.profileDidChange(try .init(sequence: 1, scope: .contactAlias(owner: owner, target: target), revision: 2))
        await dispatcher.retryVisibleProfiles()
        try await first.waitForFrames(6)
        var rooms = Set<RoomID>()
        for index in 4..<6 {
            let delta = try await probe.delta(index)
            #expect(delta.actorUserID == owner)
            rooms.insert(delta.roomID)
            guard case .presentation(let value, _) = delta.batch.results[0] else { throw CancellationError() }
            #expect(value.contactAlias?.revision.rawValue == 2 && value.contactAlias?.remarkName == nil)
        }
        #expect(rooms == Set([first.room, second.room]))
        #expect(await probe.reads == 6)
        await dispatcher.close()
    }

    @Test("public and private revision floors survive each other's invalidations")
    func independentVersionFloors() async throws {
        let f = try ChangeFixture()
        await f.probe.setAlias(owner: f.actor, revision: 1)
        await f.probe.holdNextRead()
        try await f.subscribe()
        try await changeWait { await f.probe.readWaiting }
        await f.dispatcher.profileDidChange(try .init(sequence: 1, scope: .contactAlias(owner: f.actor, target: f.author), revision: 2))
        await f.probe.setRevision(2)
        await f.dispatcher.profileDidChange(try f.change(2))
        await f.probe.releaseRead(); try await f.waitForIdle()
        #expect(await f.probe.frames.isEmpty)
        // The next public revision must not erase the alias floor.
        await f.dispatcher.retryVisibleProfiles()
        try await changeWait { await f.probe.reads == 2 }
        try await f.waitForIdle()
        #expect(await f.probe.frames.isEmpty)
        await f.probe.setAlias(owner: f.actor, revision: 2)
        await f.dispatcher.retryVisibleProfiles(at: .now + .seconds(2))
        try await f.waitForFrames(1)
        let result = try await f.probe.delta(0)
        guard case .presentation(let value, _) = result.batch.results[0] else { throw CancellationError() }
        #expect(value.view.revision.rawValue == 2 && value.contactAlias?.revision.rawValue == 2)
        await f.dispatcher.close()
    }

    @Test("relationship and each block direction invalidate both viewers independently of content versions")
    func bilateralControlVersions() async throws {
        let probe = ChangeProbe(), firstUser = UserID(uuid: UUID()), secondUser = UserID(uuid: UUID())
        await probe.setRevision(100)
        let dispatcher = V2AuthorPresentationDispatcher(configuration: try .init(mergeDelay: .zero),
            read: { request, identity in try await probe.read(request, identity: identity) })
        let a = ChangeFixture(dispatcher: dispatcher, probe: probe, actor: firstUser, author: secondUser)
        let b = ChangeFixture(dispatcher: dispatcher, probe: probe, actor: secondUser, author: firstUser)
        let unrelated = ChangeFixture(dispatcher: dispatcher, probe: probe, author: secondUser)
        for (index, page) in [a, b, unrelated].enumerated() {
            try await page.subscribe(); try await page.waitForFrames(index + 1); try await page.acknowledge(index)
        }
        await probe.deny()
        let scopes: [V2AuthorProfileChange.Scope] = [.userBlock(actor: firstUser, target: secondUser),
            .userBlock(actor: secondUser, target: firstUser), .relationship(firstUser, secondUser)]
        for (index, scope) in scopes.enumerated() {
            let event = try V2AuthorProfileChange(sequence: UInt64(index + 1), scope: scope, revision: 1)
            await dispatcher.profileDidChange(event)
            await dispatcher.retryVisibleProfiles()
            let count = 5 + index * 2
            try await a.waitForFrames(count)
            for frame in (count - 2)..<count {
                let delta = try await probe.delta(frame)
                let page = delta.actorUserID == firstUser ? a : b
                #expect(delta.actorUserID == firstUser || delta.actorUserID == secondUser)
                #expect(delta.batch.results == [.unavailable(page.key)])
                try await page.acknowledge(frame)
            }
            // Applied denials must retain their independent source versions.
            await dispatcher.profileDidChange(event)
            await dispatcher.retryVisibleProfiles(at: .now + .seconds(2))
            #expect(await probe.reads == count)
            #expect(await dispatcher.statistics().pendingKeys == 0)
        }
        await dispatcher.close()
    }

    @Test("queue rejection keeps the visible refresh obligation for a later bounded round")
    func queueRejectionRecovery() async throws {
        let probe = ChangeProbe()
        let dispatcher = V2AuthorPresentationDispatcher(configuration: try .init(maximumConnections: 3,
            maximumPendingKeys: 1, maximumPendingKeysPerConnection: 1, maximumReads: 1, mergeDelay: .zero),
            read: { request, identity in try await probe.read(request, identity: identity) })
        let a = ChangeFixture(dispatcher: dispatcher, probe: probe)
        let b = ChangeFixture(dispatcher: dispatcher, probe: probe)
        let c = ChangeFixture(dispatcher: dispatcher, probe: probe)
        await probe.holdNextRead()
        try await a.subscribe()
        try await changeWait { await probe.readWaiting }
        try await b.subscribe()
        try await c.subscribe()
        let overloaded = await dispatcher.statistics()
        #expect(overloaded.reading == 1 && overloaded.pendingKeys == 1 && overloaded.rejectedOffers == 1)
        #expect(overloaded.visibleInterests == 3)
        let retryAt = ContinuousClock.now
        await dispatcher.retryVisibleProfiles(at: retryAt)
        #expect(await dispatcher.statistics().rejectedOffers == 1)
        await probe.releaseRead()
        try await a.waitForFrames(2)
        // Queue saturation never started c's read and must not add a failure
        // cooldown. The same scheduling instant can admit it after capacity frees.
        await dispatcher.retryVisibleProfiles(at: retryAt)
        try await a.waitForFrames(3)
        var authors: [UserID] = []
        for index in 0..<3 { authors.append(try await probe.delta(index).batch.results[0].key.userID) }
        #expect(Set(authors) == Set([a.author, b.author, c.author]))
        await dispatcher.close()
    }

    @Test("a visible author changes without a new message and only applied delivery retires the refresh")
    func noMessageRequired() async throws {
        let f = try ChangeFixture()
        try await f.subscribe()
        try await f.waitForFrames(1)
        try await f.acknowledge(0)
        await f.probe.setRevision(2)
        await f.dispatcher.profileDidChange(try f.change(2))
        await f.dispatcher.retryVisibleProfiles()
        try await f.waitForFrames(2)
        #expect(try await f.probe.revisions() == [1, 2])
        // A write without an application receipt must be retried.
        await f.dispatcher.retryVisibleProfiles(at: .now + .seconds(2))
        try await f.waitForFrames(3)
        #expect(try await f.probe.revisions() == [1, 2, 2])
        try await f.acknowledge(2)
        let reads = await f.probe.reads
        await f.dispatcher.retryVisibleProfiles(at: .now + .seconds(4))
        #expect(await f.probe.reads == reads)
        #expect(await f.dispatcher.statistics().pendingKeys == 0)
        // Replay and out-of-order public events cannot invalidate revision 2.
        await f.dispatcher.profileDidChange(try f.change(1))
        await f.dispatcher.profileDidChange(try f.change(2))
        await f.dispatcher.retryVisibleProfiles(at: .now + .seconds(5))
        #expect(await f.probe.reads == reads)
        await f.dispatcher.close()
    }

    @Test("a source event during the initial read fences its stale result")
    func changeDuringInitialRead() async throws {
        let f = try ChangeFixture()
        await f.probe.holdNextRead()
        try await f.subscribe()
        try await changeWait { await f.probe.readWaiting }
        await f.probe.setRevision(2)
        await f.dispatcher.profileDidChange(try f.change(2))
        // The old read and the automatically admitted replacement are both
        // stale. Neither may satisfy the newly installed source floor.
        await f.probe.setRevision(1)
        await f.probe.releaseRead()
        try await changeWait { await f.probe.reads == 2 }
        try await f.waitForIdle()
        #expect(await f.probe.frames.isEmpty)
        await f.probe.setRevision(2)
        await f.dispatcher.retryVisibleProfiles(at: .now + .seconds(2))
        try await f.waitForFrames(1)
        #expect(try await f.probe.revisions() == [2])
        try await f.acknowledge(0)
        await f.dispatcher.close()
    }

    @Test("a removed interest retires reads and future changes", arguments: [false, true])
    func unsubscribeWhileReading(closePage: Bool) async throws {
        let f = try ChangeFixture()
        await f.probe.holdNextRead()
        try await f.subscribe()
        try await changeWait { await f.probe.readWaiting }
        if closePage { await f.dispatcher.deactivateView(connectionID: f.connection, viewID: f.view) }
        else { try await f.replace([]) }
        await f.probe.releaseRead()
        try await f.waitForIdle()
        await f.dispatcher.profileDidChange(try f.change(2))
        await f.dispatcher.retryVisibleProfiles(at: .now + .seconds(2))
        #expect(await f.probe.frames.isEmpty)
        #expect(await f.probe.reads == 1)
        #expect(await f.dispatcher.visibleSubscriptions(for: f.author).isEmpty)
        await f.dispatcher.close()
    }

    @Test("an early receipt cannot retire a failed write", arguments: [false, true])
    func receiptBeforeWrite(accepted: Bool) async throws {
        let f = try ChangeFixture()
        await f.probe.holdNextWrite(accepted: accepted)
        try await f.subscribe()
        try await changeWait { await f.probe.writeWaiting }
        try await f.acknowledge(0)
        await f.probe.releaseWrite()
        try await f.waitForIdle()
        await f.dispatcher.retryVisibleProfiles(at: .now + .seconds(2))
        if accepted {
            #expect(await f.probe.reads == 1)
            #expect(await f.dispatcher.statistics().pendingKeys == 0)
        } else {
            try await f.waitForFrames(2)
            try await f.acknowledge(1)
            #expect(await f.probe.reads == 2)
        }
        await f.dispatcher.close()
    }

    @Test("a newer source change survives an older writer's receipt and completion")
    func changeDuringWrite() async throws {
        let f = try ChangeFixture()
        await f.probe.holdNextWrite(accepted: true)
        try await f.subscribe()
        try await changeWait { await f.probe.writeWaiting }
        await f.probe.setRevision(2)
        await f.dispatcher.profileDidChange(try f.change(2))
        try await f.acknowledge(0)
        await f.probe.releaseWrite()
        try await f.waitForIdle()
        await f.dispatcher.retryVisibleProfiles()
        try await f.waitForFrames(2)
        #expect(try await f.probe.revisions() == [1, 2])
        try await f.acknowledge(1)
        await f.dispatcher.close()
    }

    @Test("unconfirmed ordinary message supplements cannot consume a source event", arguments: [false, true])
    func unconfirmedMessageHint(accepted: Bool) async throws {
        let f = try ChangeFixture()
        try await f.subscribe()
        try await f.waitForFrames(1)
        try await f.acknowledge(0)
        await f.probe.setRevision(2)
        await f.probe.holdNextWrite(accepted: accepted)
        #expect(await f.dispatcher.offer(connectionID: f.connection, roomID: f.room, authors: [f.author]))
        try await changeWait { await f.probe.writeWaiting }
        await f.dispatcher.profileDidChange(try f.change(2))
        try await f.acknowledge(1)
        await f.probe.releaseWrite()
        try await f.waitForIdle()
        await f.dispatcher.retryVisibleProfiles()
        try await f.waitForFrames(3)
        #expect(try await f.probe.revisions() == [1, 2, 2])
        try await f.acknowledge(2)
        await f.dispatcher.close()
    }

    @Test("retention reset rereads only visible authors and applied denial stops retries")
    func resetAndDenial() async throws {
        let f = try ChangeFixture()
        try await f.subscribe()
        try await f.waitForFrames(1)
        try await f.acknowledge(0)
        await f.probe.deny()
        await f.dispatcher.resetVisibleProfiles()
        await f.dispatcher.retryVisibleProfiles()
        try await f.waitForFrames(2)
        let denied = try await f.probe.delta(1)
        #expect(denied.batch.results == [.unavailable(f.key)])
        try await f.acknowledge(1)
        await f.dispatcher.retryVisibleProfiles(at: .now + .seconds(2))
        #expect(await f.probe.reads == 2)
        #expect(await f.dispatcher.statistics().pendingKeys == 0)
        await f.dispatcher.close()
    }

    @Test("worker resumes its cursor after source errors and drains non-cooperative reads on close")
    func sourceWorker() async throws {
        let probe = ChangeProbe(), source = ChangeSource(), closed = ChangeClosed()
        let runtime = V2AuthorPresentationRuntime(configuration: try .init(mergeDelay: .zero),
            ingressConfiguration: try .init(), read: { request, identity in
                try await probe.read(request, identity: identity)
            }, closeReader: { await closed.finish() })
        try await runtime.startProfileChanges(source)
        let f = ChangeFixture(dispatcher: runtime.dispatcher, probe: probe)
        try await f.subscribe()
        try await f.waitForFrames(1)
        try await f.acknowledge(0)
        #expect(await runtime.dispatcher.offer(connectionID: f.connection, roomID: f.room, authors: [f.author]))
        #expect(await probe.reads == 1)
        #expect(await runtime.dispatcher.statistics().suppressedReads == 1)
        await source.failNextRead()
        try await changeWait { await runtime.profileChangeFailures() > 0 }
        #expect(await runtime.dispatcher.offer(connectionID: f.connection, roomID: f.room, authors: [f.author]))
        try await changeWait { await probe.reads == 2 }
        try await f.waitForIdle()
        #expect(await runtime.dispatcher.statistics().suppressedReads == 1)
        await probe.setRevision(2)
        await source.publish(try f.change(2))
        try await f.waitForFrames(2)
        #expect(try await probe.revisions() == [1, 2])
        try await f.acknowledge(1)
        await source.holdNextRead()
        try await changeWait { await source.waiting }
        let first = Task { await runtime.close() }, second = Task { await runtime.close() }
        first.cancel()
        try await changeWait { await source.cancelled }
        #expect(await closed.count == 0)
        await source.release()
        await first.value; await second.value
        #expect(await closed.count == 1)
        #expect(await runtime.dispatcher.statistics().connections == 0)
    }

    @Test("shutdown drains a cancelled bootstrap before releasing dependencies")
    func closeDuringBootstrap() async throws {
        let source = ChangeSource(), closed = ChangeClosed()
        await source.holdNextRead()
        let runtime = V2AuthorPresentationRuntime(configuration: try .init(), ingressConfiguration: try .init(),
            readBatch: { _ in [] }, closeReader: { await closed.finish() })
        let start = Task { try await runtime.startProfileChanges(source) }
        try await changeWait { await source.waiting }
        let finish = Task { await runtime.close() }
        try await changeWait { await source.cancelled }
        #expect(await closed.count == 0)
        await source.release()
        await #expect(throws: (any Error).self) { try await start.value }
        await finish.value
        #expect(await closed.count == 1)
    }
}

private struct ChangeFixture {
    let dispatcher: V2AuthorPresentationDispatcher
    let probe: ChangeProbe
    let connection = UUID(), stream = UUID(), view = UUID()
    let room: RoomID, author: UserID, actor: UserID
    var key: V2ProfileViewLookupKey { .init(userID: author, context: .room(room)) }
    init() throws {
        room = .init(uuid: UUID()); author = .init(uuid: UUID()); actor = .init(uuid: UUID())
        let probe = ChangeProbe(); self.probe = probe
        dispatcher = .init(configuration: try .init(mergeDelay: .zero), read: { request, identity in
            try await probe.read(request, identity: identity)
        })
    }
    init(dispatcher: V2AuthorPresentationDispatcher, probe: ChangeProbe,
         actor: UserID = .init(uuid: UUID()), author: UserID = .init(uuid: UUID()), room: RoomID = .init(uuid: UUID())) {
        self.dispatcher = dispatcher; self.probe = probe; self.actor = actor; self.author = author; self.room = room
    }
    func subscribe() async throws {
        _ = try await dispatcher.registerFixture(connectionID: connection,
            identity: .init(userID: actor, deviceID: .init(uuid: UUID()), capabilityProfile: "standard"),
            streamID: stream, send: { bytes, _ in await probe.send(bytes) })
        #expect(await dispatcher.activateRoomFixture(connectionID: connection, roomID: room, viewID: view))
        #expect(await dispatcher.replaceVisibleInterests(connectionID: connection, interests: try .init(
            streamID: stream, viewID: view, roomID: room, sequence: 1, userIDs: [author])))
    }
    func replace(_ authors: [UserID]) async throws {
        #expect(await dispatcher.replaceVisibleInterests(connectionID: connection, interests: try .init(
            streamID: stream, viewID: view, roomID: room, sequence: 2, userIDs: authors)))
    }
    func acknowledge(_ index: Int) async throws {
        let delta = try await probe.delta(index)
        await dispatcher.acknowledge(connectionID: connection, receipt: try .init(streamID: stream, viewID: view,
            roomID: room, sequence: delta.sequence, userIDs: [author]))
    }
    func change(_ revision: UInt64) throws -> V2AuthorProfileChange {
        try .init(sequence: 1, userID: author, revision: revision)
    }
    func waitForFrames(_ count: Int) async throws {
        try await changeWait { await probe.frames.count >= count }
        try await waitForIdle()
    }
    func waitForIdle() async throws {
        try await changeWait {
            let state = await dispatcher.statistics()
            return state.reading == 0 && state.writing == 0 && state.pendingKeys == 0 && state.outputBytes == 0
        }
    }
}

private actor ChangeProbe {
    var reads = 0, revision: UInt64 = 1
    var frames: [Data] = []
    var readWaiting: Bool { readContinuation != nil }
    var writeWaiting: Bool { writeContinuation != nil }
    private var denyRead = false, holdRead = false, holdWrite = false, writeAccepted = true
    private var readContinuation: CheckedContinuation<Void, Never>?, writeContinuation: CheckedContinuation<Void, Never>?
    private var aliases: [UserID: (revision: UInt64, name: String?)] = [:]
    private var nicknames: [V2ProfileViewLookupKey: V2GroupMemberPresentation] = [:]
    func setRevision(_ revision: UInt64) { self.revision = revision }
    func setAlias(owner: UserID, revision: UInt64, name: String? = "Alias") { aliases[owner] = (revision, name) }
    func setNickname(room: RoomID, author: UserID, revision: UInt64, name: String? = "Member") throws {
        nicknames[.init(userID: author, context: .room(room))] = try .init(roomID: room, userID: author,
            groupNickname: name, revision: #require(.init(rawValue: revision)))
    }
    func deny() { denyRead = true }
    func holdNextRead() { holdRead = true }
    func holdNextWrite(accepted: Bool) { holdWrite = true; writeAccepted = accepted }
    func releaseRead() { readContinuation?.resume(); readContinuation = nil }
    func releaseWrite() { writeContinuation?.resume(); writeContinuation = nil }
    func read(_ request: V2ProfilePresentationBatchRequest, identity: V2AuthenticatedConnection) async throws -> V2ProfilePresentationBatchResponse {
        reads += 1
        let captured = revision, denied = denyRead, alias = aliases[identity.userID], members = nicknames
        if holdRead { holdRead = false; await withCheckedContinuation { readContinuation = $0 } }
        let now = Date(), entries = try request.keys.map { key -> V2ProfilePresentationBatchEntry in
            if denied { return .unavailable(key) }
            let view = try V2ProfileView(userID: key.userID, publicIdentity: .init(userID: key.userID,
                handle: .init("author"), displayName: "Author", accountKind: .regular), avatar: nil, state: .active,
                revision: #require(.init(rawValue: captured)), visibilityRevision: #require(.init(rawValue: 1)))
            let lease = try V2PresentationAccessLease(actorUserID: identity.userID, deviceID: identity.deviceID, key: key,
                profileRevision: view.revision, visibilityRevision: view.visibilityRevision, contextRevision: 3, observedAt: now,
                validUntil: now.addingTimeInterval(120))
            let remark = try alias.map { try V2ContactAlias(ownerUserID: identity.userID, targetUserID: key.userID,
                remarkName: $0.name, revision: #require(.init(rawValue: $0.revision))) }
            return .presentation(try .init(view: view, lease: lease, groupMember: members[key], contactAlias: remark), avatar: nil)
        }
        return try .init(serverNowUnixMilliseconds: Int64((now.timeIntervalSince1970 * 1_000).rounded(.down)), results: entries)
    }
    func send(_ bytes: Data) async -> Bool {
        frames.append(bytes)
        let accepted = writeAccepted; writeAccepted = true
        if holdWrite { holdWrite = false; await withCheckedContinuation { writeContinuation = $0 } }
        return accepted
    }
    func delta(_ index: Int) throws -> V2AuthorPresentationDelta { try .decode(frames[index]) }
    func revisions() throws -> [UInt64] {
        try frames.map { bytes in
            let delta = try V2AuthorPresentationDelta.decode(bytes)
            guard case .presentation(let presentation, _) = delta.batch.results[0] else { return 0 }
            return presentation.view.revision.rawValue
        }
    }
}

private actor ChangeClosed { var count = 0; func finish() { count += 1 } }
private actor ChangeSource: V2AuthorProfileChangeReading {
    var waiting: Bool { continuation != nil }
    var cancelled = false
    private var hold = false, fail = false
    private var changes: [V2AuthorProfileChange] = []
    private var continuation: CheckedContinuation<Void, Never>?
    func publish(_ change: V2AuthorProfileChange) { changes.append(change) }
    func failNextRead() { fail = true }
    func holdNextRead() { hold = true }
    func release() { continuation?.resume(); continuation = nil }
    func readChanges(after cursor: UInt64?) async throws -> V2AuthorProfileChangeBatch {
        if hold {
            hold = false
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation = $0 }
            } onCancel: { Task { await self.observeCancellation() } }
        }
        if fail { fail = false; throw V2ResourceProviderError.configurationInvalid }
        return try .init(head: changes.last?.sequence ?? 0, resetRequired: cursor == nil,
            changes: cursor.map { cursor in changes.filter { $0.sequence > cursor } } ?? [])
    }
    private func observeCancellation() { cancelled = true }
}
private func changeWait(_ predicate: () async -> Bool) async throws {
    let end = ContinuousClock.now + .seconds(5)
    while !(await predicate()) {
        guard .now < end else { throw CancellationError() }
        try await Task.sleep(for: .milliseconds(1))
    }
}
