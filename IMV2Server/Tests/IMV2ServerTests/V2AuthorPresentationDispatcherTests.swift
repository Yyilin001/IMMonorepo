import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

@Suite(.serialized)
struct V2AuthorPresentationDispatcherTests {
    @Test("queued messages coalesce distinct authors without an extra authority call per event")
    func mergeQueuedAuthors() async throws {
        let probe = Probe(holdReads: true), worker = V2AuthorPresentationDispatcher(
            configuration: try .init(maximumReads: 1), read: probe.read)
        let a = UUID(), b = UUID(), room = RoomID(uuid: UUID())
        do {
            for connection in [a, b] {
                _ = try await worker.register(connectionID: connection, identity: identity(), send: probe.send)
                #expect(await worker.activateView(connectionID: connection, roomID: room, viewID: UUID()))
            }
            #expect(await worker.offer(connectionID: a, roomID: room, authors: [.init(uuid: UUID())]))
            try await wait { await probe.readCount == 1 }
            let authors = (0..<3).map { _ in UserID(uuid: UUID()) }
            for author in authors { #expect(await worker.offer(connectionID: b, roomID: room, authors: [author, author])) }
            #expect(await worker.statistics().pendingKeys == 3)
            await probe.releaseReads()
            try await wait { await worker.statistics().deliveredFrames == 2 }
            #expect(await probe.requestSizes == [1, 3])
            await worker.close()
        } catch { await probe.releaseReads(); await worker.close(); throw error }
    }

    @Test("compression never suppresses a lease shorter than the client's causal timing deduction")
    func shortLeaseSuppression() async throws {
        let probe = Probe(), worker = V2AuthorPresentationDispatcher(configuration: try .init(mergeDelay: .zero), read: probe.read)
        let connection = UUID(), room = RoomID(uuid: UUID()), author = UserID(uuid: UUID())
        do {
            await probe.setLifetime(20)
            _ = try await worker.register(connectionID: connection, identity: identity(), send: probe.send)
            #expect(await worker.activateView(connectionID: connection, roomID: room, viewID: UUID()))
            #expect(await worker.offer(connectionID: connection, roomID: room, authors: [author]))
            try await wait { await worker.statistics().deliveredFrames == 1 }
            #expect(await worker.statistics().hintBytes == 0)
            #expect(await worker.offer(connectionID: connection, roomID: room, authors: [author]))
            try await wait { await worker.statistics().deliveredFrames == 2 }
            #expect(await worker.statistics().suppressedEntries == 0)
            await worker.close()
        } catch { await worker.close(); throw error }
    }

    @Test("output saturation stops optional authority reads until the writer drains")
    func outputBackpressure() async throws {
        let probe = Probe(holdWrites: true), worker = V2AuthorPresentationDispatcher(
            configuration: try .init(maximumReads: 1, maximumWrites: 1, maximumOutputBytes: 32_768, mergeDelay: .zero), read: probe.read)
        do {
            let a = UUID(), b = UUID(), room = RoomID(uuid: UUID())
            for connection in [a, b] {
                _ = try await worker.register(connectionID: connection, identity: identity(), send: probe.send)
                #expect(await worker.activateView(connectionID: connection, roomID: room, viewID: UUID()))
            }
            #expect(await worker.offer(connectionID: a, roomID: room, authors: [.init(uuid: UUID())]))
            try await wait { await worker.statistics().writing == 1 }
            #expect(await worker.offer(connectionID: b, roomID: room, authors: [.init(uuid: UUID())]))
            #expect(await probe.readCount == 1)
            #expect(await worker.statistics().pendingKeys == 1)
            await probe.releaseWrites()
            try await wait { await worker.statistics().deliveredFrames == 2 }
            #expect(await probe.readCount == 2)
            await worker.close()
        } catch { await probe.releaseWrites(); await worker.close(); throw error }
    }

    @Test("encoded demand bytes and total connection admission reject before starting readers")
    func byteAndConnectionAdmission() async throws {
        let probe = Probe(), room = RoomID(uuid: UUID()), authors = (0..<3).map { _ in UserID(uuid: UUID()) }
        let cost = try authors.reduce(0) { $0 + (try JSONEncoder().encode(V2ProfileViewLookupKey(userID: $1, context: .room(room))).count) }
        let worker = V2AuthorPresentationDispatcher(configuration: try .init(maximumConnections: 1,
            maximumPendingKeys: 3, maximumPendingKeysPerConnection: 3, maximumPendingBytes: cost - 1, mergeDelay: .zero), read: probe.read)
        do {
            let connection = UUID()
            _ = try await worker.register(connectionID: connection, identity: identity(), send: probe.send)
            #expect(await worker.activateView(connectionID: connection, roomID: room, viewID: UUID()))
            #expect(!(await worker.offer(connectionID: connection, roomID: room, authors: authors)))
            #expect(await worker.statistics().pendingBytes == 0)
            #expect(await probe.readCount == 0)
            await #expect(throws: V2ResourceProviderError.throttled(retryAfter: 1)) {
                _ = try await worker.register(connectionID: UUID(), identity: identity(), send: probe.send)
            }
            await worker.close()
        } catch { await worker.close(); throw error }
    }

    @Test("leaving and re-entering the same room fences old page work on the same connection", arguments: [false, true])
    func pageGeneration(reusesNonce: Bool) async throws {
        let probe = Probe(holdReads: true), worker = V2AuthorPresentationDispatcher(
            configuration: try .init(maximumReads: 1, mergeDelay: .zero), read: probe.read)
        let connection = UUID(), room = RoomID(uuid: UUID()), oldView = UUID()
        let nextView = reusesNonce ? oldView : UUID()
        do {
            _ = try await worker.register(connectionID: connection, identity: identity(), send: probe.send)
            #expect(!(await worker.offer(connectionID: connection, roomID: room, authors: [.init(uuid: UUID())])))
            #expect(await worker.activateView(connectionID: connection, roomID: room, viewID: oldView))
            #expect(await worker.offer(connectionID: connection, roomID: room, authors: [.init(uuid: UUID())]))
            try await wait { await probe.readCount == 1 }
            await worker.deactivateView(connectionID: connection, viewID: oldView)
            #expect(await worker.activateView(connectionID: connection, roomID: room, viewID: nextView))
            if !reusesNonce { await worker.deactivateView(connectionID: connection, viewID: oldView) }
            #expect(await worker.offer(connectionID: connection, roomID: room, authors: [.init(uuid: UUID())]))
            #expect(await worker.statistics().reading == 1)
            await probe.releaseReads()
            try await wait { await worker.statistics().deliveredFrames == 1 }
            #expect(await probe.frames.map(\.viewID) == [nextView])
            await worker.close()
        } catch { await probe.releaseReads(); await worker.close(); throw error }
    }

    @Test("offers return while authority is suspended; duplicate authors and queue limits remain bounded")
    func independentOffersAndAdmission() async throws {
        let probe = Probe(holdReads: true), connection = UUID(), room = RoomID(uuid: UUID()), author = UserID(uuid: UUID())
        let worker = V2AuthorPresentationDispatcher(configuration: try .init(maximumPendingKeys: 2,
            maximumPendingKeysPerConnection: 2, maximumReads: 1, mergeDelay: .zero), read: probe.read)
        do {
            _ = try await worker.register(connectionID: connection, identity: identity(), send: probe.send)
            #expect(await worker.activateView(connectionID: connection, roomID: room, viewID: UUID()))
            #expect(await worker.offer(connectionID: connection, roomID: room, authors: [author, author]))
            try await wait { await probe.readCount == 1 }
            for _ in 0..<100 { #expect(await worker.offer(connectionID: connection, roomID: room, authors: [author])) }
            #expect(await worker.statistics().pendingKeys == 0)
            #expect(await worker.offer(connectionID: connection, roomID: room, authors: [.init(uuid: UUID()), .init(uuid: UUID())]))
            #expect(!(await worker.offer(connectionID: connection, roomID: room, authors: [.init(uuid: UUID())])))
            #expect(await worker.statistics().pendingKeys == 2)
            #expect(await worker.statistics().reading == 1)
            await probe.releaseReads()
            try await wait {
                let value = await worker.statistics()
                return value.reading == 0 && value.pendingKeys == 0
            }
            await worker.close()
        } catch { await probe.releaseReads(); await worker.close(); throw error }
    }

    @Test("identical versions suppress bytes only after fresh authorization; changed and denied results still emit")
    func compressionDoesNotAuthorize() async throws {
        let probe = Probe(), connection = UUID(), room = RoomID(uuid: UUID()), author = UserID(uuid: UUID())
        let worker = V2AuthorPresentationDispatcher(configuration: try .init(mergeDelay: .zero), read: probe.read)
        do {
            let stream = try await worker.register(connectionID: connection, identity: identity(), send: probe.send)
            #expect(await worker.activateView(connectionID: connection, roomID: room, viewID: UUID()))
            #expect(await worker.offer(connectionID: connection, roomID: room, authors: [author]))
            try await wait { await worker.statistics().deliveredFrames == 1 }
            #expect(await worker.offer(connectionID: connection, roomID: room, authors: [author]))
            try await wait { await worker.statistics().suppressedEntries == 1 }
            #expect(await probe.readCount == 2)
            #expect(await probe.frames.count == 1)
            await probe.setRevision(2)
            #expect(await worker.offer(connectionID: connection, roomID: room, authors: [author]))
            try await wait { await worker.statistics().deliveredFrames == 2 }
            await probe.setDenied()
            #expect(await worker.offer(connectionID: connection, roomID: room, authors: [author]))
            try await wait { await worker.statistics().deliveredFrames == 3 }
            let frames = await probe.frames
            #expect(frames.map(\.streamID) == [stream, stream, stream])
            #expect(frames.map(\.sequence) == [1, 2, 3])
            #expect(frames[2].batch.results == [.unavailable(.init(userID: author, context: .room(room)))])
            #expect(await worker.statistics().hintBytes == 0)
            await worker.close()
        } catch { await worker.close(); throw error }
    }

    @Test("a slow socket uses its write budget without holding a database read slot")
    func independentWriteBudget() async throws {
        let probe = Probe(holdWrites: true), worker = V2AuthorPresentationDispatcher(
            configuration: try .init(maximumReads: 1, maximumWrites: 1, mergeDelay: .zero), read: probe.read)
        do {
            for _ in 0..<3 {
                let connection = UUID(), room = RoomID(uuid: UUID())
                _ = try await worker.register(connectionID: connection, identity: identity(), send: probe.send)
                #expect(await worker.activateView(connectionID: connection, roomID: room, viewID: UUID()))
                #expect(await worker.offer(connectionID: connection, roomID: room, authors: [.init(uuid: UUID())]))
            }
            try await wait {
                let value = await worker.statistics()
                return await probe.readCount == 3 && value.reading == 0
            }
            let before = await worker.statistics()
            #expect(before.writing == 1 && before.outputBytes > 0)
            let closeA = Task { await worker.close() }, closeB = Task { await worker.close() }
            try await wait { await worker.statistics().connections == 0 }
            #expect(await worker.statistics().writing == 1)
            #expect(await worker.statistics().outputBytes > 0)
            await probe.releaseWrites()
            await closeA.value; await closeB.value
            #expect(await worker.statistics().writing == 0)
            #expect(await worker.statistics().outputBytes == 0)
            #expect(await worker.statistics().deliveredFrames == 0)
        } catch { await probe.releaseWrites(); await worker.close(); throw error }
    }

    @Test("unregister and replacement keep old non-cooperative reads charged and discard their results")
    func replacementGeneration() async throws {
        let probe = Probe(holdReads: true), worker = V2AuthorPresentationDispatcher(
            configuration: try .init(maximumReads: 1, mergeDelay: .zero), read: probe.read)
        let connection = UUID(), room = RoomID(uuid: UUID()), author = UserID(uuid: UUID())
        do {
            let old = try await worker.register(connectionID: connection, identity: identity(), send: probe.send)
            #expect(await worker.activateView(connectionID: connection, roomID: room, viewID: UUID()))
            #expect(await worker.offer(connectionID: connection, roomID: room, authors: [author]))
            try await wait { await probe.readCount == 1 }
            await worker.unregister(connectionID: connection)
            let newIdentity = identity()
            let replacement = try await worker.register(connectionID: connection, identity: newIdentity, send: probe.send)
            #expect(await worker.activateView(connectionID: connection, roomID: room, viewID: UUID()))
            #expect(replacement != old)
            #expect(await worker.offer(connectionID: connection, roomID: room, authors: [author]))
            #expect(await worker.statistics().reading == 1)
            #expect(await worker.statistics().pendingKeys == 1)
            await probe.releaseReads()
            try await wait { await worker.statistics().deliveredFrames == 1 }
            let frame = try #require(await probe.frames.first)
            #expect(frame.streamID == replacement && frame.actorUserID == newIdentity.userID)
            #expect(await probe.frames.count == 1)
            await worker.close()
        } catch { await probe.releaseReads(); await worker.close(); throw error }
    }

    @Test("expired authority work retains its slot until return and emits no late delta")
    func deadlineAndClose() async throws {
        let probe = Probe(holdReads: true), worker = V2AuthorPresentationDispatcher(
            configuration: try .init(maximumReads: 1, mergeDelay: .zero, lifetime: .milliseconds(40)), read: probe.read)
        let connection = UUID(), room = RoomID(uuid: UUID())
        do {
            _ = try await worker.register(connectionID: connection, identity: identity(), send: probe.send)
            #expect(await worker.activateView(connectionID: connection, roomID: room, viewID: UUID()))
            #expect(await worker.offer(connectionID: connection, roomID: room, authors: [.init(uuid: UUID())]))
            try await wait { await worker.statistics().expiredJobs == 1 }
            #expect(await worker.statistics().reading == 1)
            let closeA = Task { await worker.close() }, closeB = Task { await worker.close() }
            try await wait { await worker.statistics().connections == 0 }
            #expect(await worker.statistics().reading == 1)
            await probe.releaseReads()
            await closeA.value; await closeB.value
            #expect(await worker.statistics().reading == 0)
            #expect(await probe.frames.isEmpty)
            #expect(!(await worker.offer(connectionID: connection, roomID: room, authors: [.init(uuid: UUID())])))
        } catch { await probe.releaseReads(); await worker.close(); throw error }
    }

    @Test("wrong recipient results are discarded and throttling remains retryable")
    func invalidRecipientAndRetry() async throws {
        let probe = Probe(), worker = V2AuthorPresentationDispatcher(configuration: try .init(mergeDelay: .zero), read: probe.read)
        let connection = UUID(), room = RoomID(uuid: UUID()), author = UserID(uuid: UUID())
        do {
            _ = try await worker.register(connectionID: connection, identity: identity(), send: probe.send)
            #expect(await worker.activateView(connectionID: connection, roomID: room, viewID: UUID()))
            await probe.setWrongRecipient()
            #expect(await worker.offer(connectionID: connection, roomID: room, authors: [author]))
            try await wait {
                let value = await worker.statistics()
                return await probe.readCount == 1 && value.reading == 0
            }
            #expect(await probe.frames.isEmpty)
            await probe.setThrottle(.nan)
            #expect(await worker.offer(connectionID: connection, roomID: room, authors: [author]))
            try await wait { await worker.statistics().deliveredFrames == 1 }
            let frame = try #require(await probe.frames.first)
            #expect(frame.retryAfterMilliseconds == 1_000)
            #expect(frame.batch.results == [.retryable(.init(userID: author, context: .room(room)))])
            await worker.close()
        } catch { await worker.close(); throw error }
    }

    @Test("oversized capability payloads become bounded partial retryable output")
    func byteBudget() async throws {
        let probe = Probe(), worker = V2AuthorPresentationDispatcher(configuration: try .init(mergeDelay: .zero), read: probe.read)
        let connection = UUID(), room = RoomID(uuid: UUID())
        do {
            await probe.setLargeAvatars()
            _ = try await worker.register(connectionID: connection, identity: identity(), send: probe.send)
            #expect(await worker.activateView(connectionID: connection, roomID: room, viewID: UUID()))
            #expect(await worker.offer(connectionID: connection, roomID: room, authors: (0..<16).map { _ in .init(uuid: UUID()) }))
            try await wait { await worker.statistics().deliveredFrames == 1 }
            let frame = try #require(await probe.frames.first)
            #expect(try frame.encoded().count <= V2AuthorPresentationDelta.maximumEncodedBytes)
            #expect(frame.batch.results.count == 16)
            #expect(frame.batch.results.contains { if case .retryable = $0 { true } else { false } })
            #expect(frame.batch.results.contains { if case .presentation = $0 { true } else { false } })
            await worker.close()
        } catch { await worker.close(); throw error }
    }

    private func identity() -> V2AuthenticatedConnection {
        .init(userID: .init(uuid: UUID()), deviceID: .init(uuid: UUID()), capabilityProfile: "standard")
    }
    private func wait(_ ready: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await ready()) {
            guard ContinuousClock.now < deadline else { throw ProbeFailure.timeout }
            await Task.yield()
        }
    }
}

private enum ProbeFailure: Error { case timeout }
private actor Probe {
    var readCount = 0
    var requestSizes: [Int] = []
    var frames: [V2AuthorPresentationDelta] = []
    private var holdReads: Bool, holdWrites: Bool
    private var readWaiters: [CheckedContinuation<Void, Never>] = [], writeWaiters: [CheckedContinuation<Void, Never>] = []
    private var revision: UInt64 = 1
    private var denied = false, wrongRecipient = false, largeAvatars = false
    private var throttle: TimeInterval?
    private var lifetime: TimeInterval = 120

    init(holdReads: Bool = false, holdWrites: Bool = false) { self.holdReads = holdReads; self.holdWrites = holdWrites }
    func setRevision(_ value: UInt64) { revision = value }
    func setDenied() { denied = true }
    func setWrongRecipient() { wrongRecipient = true }
    func setThrottle(_ value: TimeInterval) { wrongRecipient = false; throttle = value }
    func setLargeAvatars() { largeAvatars = true }
    func setLifetime(_ value: TimeInterval) { lifetime = value }
    func releaseReads() { holdReads = false; let values = readWaiters; readWaiters.removeAll(); for value in values { value.resume() } }
    func releaseWrites() { holdWrites = false; let values = writeWaiters; writeWaiters.removeAll(); for value in values { value.resume() } }

    func read(_ request: V2ProfilePresentationBatchRequest, _ identity: V2AuthenticatedConnection) async throws -> V2ProfilePresentationBatchResponse {
        readCount += 1
        requestSizes.append(request.keys.count)
        if holdReads { await withCheckedContinuation { readWaiters.append($0) } }
        if let throttle { throw V2ResourceProviderError.throttled(retryAfter: throttle) }
        let now = Date(), revision = try #require(V2ProfileRevision(rawValue: revision))
        let results = try request.keys.map { key -> V2ProfilePresentationBatchEntry in
            if denied { return .unavailable(key) }
            let mediaID = largeAvatars ? MediaID(uuid: UUID()) : nil
            let view = try V2ProfileView(userID: key.userID,
                publicIdentity: .init(userID: key.userID, handle: .init("author"), displayName: "Author", accountKind: .regular),
                avatar: mediaID.map(V2AvatarReference.init), state: .active, revision: revision, visibilityRevision: revision)
            let lease = try V2PresentationAccessLease(actorUserID: wrongRecipient ? .init(uuid: UUID()) : identity.userID,
                deviceID: identity.deviceID, key: key, profileRevision: revision, visibilityRevision: revision,
                contextRevision: 3, observedAt: now, validUntil: now.addingTimeInterval(lifetime))
            let access: V2ResourceAvatarAccess?
            if let mediaID {
                let checksum = try V2ResourceChecksum(value: String(repeating: "a", count: 64))
                let url = try #require(URL(string: "https://objects.invalid/a?token=" + String(repeating: "x", count: 7_500)))
                access = try .init(mediaID: mediaID, variantID: .init(uuid: UUID()), version: 1, checksum: checksum,
                    plan: .init(mode: .httpGet, url: url, expiresAt: now.addingTimeInterval(100), expectedByteCount: 10, checksum: checksum))
            } else { access = nil }
            return .presentation(try .init(view: view, lease: lease), avatar: access)
        }
        return try .init(serverNowUnixMilliseconds: Int64((now.timeIntervalSince1970 * 1_000).rounded(.down)), results: results)
    }
    func send(_ data: Data, _ deadline: ContinuousClock.Instant) async -> Bool {
        if holdWrites { await withCheckedContinuation { writeWaiters.append($0) } }
        guard !Task.isCancelled, deadline > .now, let frame = try? V2AuthorPresentationDelta.decode(data) else { return false }
        frames.append(frame); return true
    }
}
