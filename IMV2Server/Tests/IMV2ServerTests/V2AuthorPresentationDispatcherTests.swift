@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing

@Suite(.serialized)
struct V2AuthorPresentationDispatcherTests {
    @Test("early receipt is usable only after a successful write", arguments: [true, false])
    func receiptRacesWrite(accepted: Bool) async throws {
        let probe = Probe(), connection = UUID(), room = RoomID(uuid: UUID()), author = UserID(uuid: UUID())
        let worker = V2AuthorPresentationDispatcher(configuration: try .init(mergeDelay: .zero), read: probe.read)
        do {
            await probe.setReceipt { frame in
                await worker.acknowledge(connectionID: connection, receipt: try! .init(streamID: frame.streamID,
                    viewID: frame.viewID, roomID: room, sequence: frame.sequence, userIDs: [author]))
            }
            await probe.setWriteAccepted(accepted)
            _ = try await worker.registerFixture(connectionID: connection, identity: identity(), send: probe.send)
            #expect(await worker.activateRoomFixture(connectionID: connection, roomID: room, viewID: UUID()))
            #expect(await worker.offer(connectionID: connection, roomID: room, authors: [author]))
            try await wait {
                let writing = await worker.statistics().writing
                return await probe.frames.count == 1 && writing == 0
            }
            #expect(await worker.offer(connectionID: connection, roomID: room, authors: [author]))
            if accepted {
                try await wait { await worker.statistics().suppressedEntries == 1 }
                #expect(await probe.frames.count == 1)
            } else {
                try await wait {
                let writing = await worker.statistics().writing
                return await probe.frames.count == 2 && writing == 0
            }
                #expect(await worker.statistics().hintBytes == 0)
            }
            await probe.setReceipt(nil); await worker.close()
        } catch { await probe.setReceipt(nil); await worker.close(); throw error }
    }

    @Test("socket completion alone and receipts for other views or sequences never suppress missing entries")
    func explicitReceiptRequired() async throws {
        let probe = Probe(), connection = UUID(), room = RoomID(uuid: UUID()), author = UserID(uuid: UUID())
        let worker = V2AuthorPresentationDispatcher(configuration: try .init(mergeDelay: .zero), read: probe.read)
        do {
            _ = try await worker.registerFixture(connectionID: connection, identity: identity(), send: probe.send)
            #expect(await worker.activateRoomFixture(connectionID: connection, roomID: room, viewID: UUID()))
            #expect(await worker.offer(connectionID: connection, roomID: room, authors: [author]))
            try await wait { await worker.statistics().deliveredFrames == 1 }
            let first = try #require(await probe.frames.first)
            for receipt in [
                try V2AuthorPresentationReceipt(streamID: UUID(), viewID: first.viewID, roomID: room, sequence: 1, userIDs: [author]),
                try .init(streamID: first.streamID, viewID: UUID(), roomID: room, sequence: 1, userIDs: [author]),
                try .init(streamID: first.streamID, viewID: first.viewID, roomID: room, sequence: 2, userIDs: [author]),
                try .init(streamID: first.streamID, viewID: first.viewID, roomID: room, sequence: 1, userIDs: [.init(uuid: UUID())])
            ] { await worker.acknowledge(connectionID: connection, receipt: receipt) }
            #expect(await worker.offer(connectionID: connection, roomID: room, authors: [author]))
            try await wait { await worker.statistics().deliveredFrames == 2 }
            // A receipt for the dropped first frame is not cumulative and must
            // not acknowledge the replacement frame's entries.
            await worker.acknowledge(connectionID: connection, receipt: try .init(streamID: first.streamID,
                viewID: first.viewID, roomID: room, sequence: 1, userIDs: [author]))
            #expect(await worker.offer(connectionID: connection, roomID: room, authors: [author]))
            try await wait { await worker.statistics().deliveredFrames == 3 }
            #expect(await worker.statistics().suppressedEntries == 0)
            let last = try #require(await probe.frames.last)
            await worker.acknowledge(connectionID: connection, receipt: try .init(streamID: last.streamID,
                viewID: last.viewID, roomID: room, sequence: last.sequence, userIDs: [author]))
            #expect(await worker.offer(connectionID: connection, roomID: room, authors: [author]))
            try await wait { await worker.statistics().suppressedEntries == 1 }
            #expect(await probe.frames.count == 3)
            await worker.close()
            #expect(await worker.statistics().hintBytes == 0)
        } catch { await worker.close(); throw error }
    }

    @Test("queued messages coalesce distinct authors without an extra authority call per event")
    func mergeQueuedAuthors() async throws {
        let probe = Probe(holdReads: true), worker = V2AuthorPresentationDispatcher(
            configuration: try .init(maximumReads: 1), read: probe.read)
        let a = UUID(), b = UUID(), room = RoomID(uuid: UUID())
        do {
            for connection in [a, b] {
                _ = try await worker.registerFixture(connectionID: connection, identity: identity(), send: probe.send)
                #expect(await worker.activateRoomFixture(connectionID: connection, roomID: room, viewID: UUID()))
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

    @Test("short leases create only unconfirmed hints until the client reports retention")
    func shortLeaseSuppression() async throws {
        let probe = Probe(), worker = V2AuthorPresentationDispatcher(configuration: try .init(mergeDelay: .zero), read: probe.read)
        let connection = UUID(), room = RoomID(uuid: UUID()), author = UserID(uuid: UUID())
        do {
            await probe.setLifetime(20)
            _ = try await worker.registerFixture(connectionID: connection, identity: identity(), send: probe.send)
            #expect(await worker.activateRoomFixture(connectionID: connection, roomID: room, viewID: UUID()))
            #expect(await worker.offer(connectionID: connection, roomID: room, authors: [author]))
            try await wait { await worker.statistics().deliveredFrames == 1 }
            #expect(await worker.statistics().hintBytes > 0)
            #expect(await worker.offer(connectionID: connection, roomID: room, authors: [author]))
            try await wait { await worker.statistics().deliveredFrames == 2 }
            #expect(await worker.statistics().suppressedEntries == 0)
            await worker.close()
        } catch { await worker.close(); throw error }
    }

    @Test("confirmed visible entries avoid authority reads only while the change source is caught up")
    func suppressBeforeRead() async throws {
        let probe = Probe(), worker = V2AuthorPresentationDispatcher(configuration: try .init(mergeDelay: .zero), read: probe.read)
        let connection = UUID(), room = RoomID(uuid: UUID()), author = UserID(uuid: UUID()), view = UUID()
        do {
            await probe.setLifetime(5)
            let stream = try await worker.registerFixture(connectionID: connection, identity: identity(), send: probe.send)
            #expect(await worker.activateRoomFixture(connectionID: connection, roomID: room, viewID: view))
            #expect(await worker.replaceVisibleInterests(connectionID: connection,
                interests: try .init(streamID: stream, viewID: view, roomID: room, sequence: 1, userIDs: [author])))
            try await wait { await worker.statistics().deliveredFrames == 1 }
            let first = try #require(await probe.frames.first)
            await worker.acknowledge(connectionID: connection, receipt: try .init(streamID: stream, viewID: view,
                roomID: room, sequence: first.sequence, userIDs: [author], minimumRemainingMilliseconds: 4_000))
            await worker.profileSourceCaughtUp()
            for _ in 0..<10 { #expect(await worker.offer(connectionID: connection, roomID: room, authors: [author])) }
            #expect(await probe.readCount == 1)
            #expect(await worker.statistics().suppressedReads == 10)
            await probe.setRevision(2)
            await worker.profileDidChange(try .init(sequence: 1, scope: .publicProfile(author), revision: 2))
            #expect(await worker.offer(connectionID: connection, roomID: room, authors: [author]))
            try await wait { await worker.statistics().deliveredFrames == 2 }
            let second = try #require(await probe.frames.last)
            await worker.acknowledge(connectionID: connection, receipt: try .init(streamID: stream, viewID: view,
                roomID: room, sequence: second.sequence, userIDs: [author], minimumRemainingMilliseconds: 4_000))
            await worker.profileSourceUnavailable()
            #expect(await worker.offer(connectionID: connection, roomID: room, authors: [author]))
            try await wait { let reading = await worker.statistics().reading; return await probe.readCount == 3 && reading == 0 }
            #expect(await worker.statistics().suppressedReads == 10)
            await worker.profileSourceCaughtUp()
            try await Task.sleep(for: .milliseconds(1_050))
            #expect(await worker.offer(connectionID: connection, roomID: room, authors: [author]))
            try await wait { let reading = await worker.statistics().reading; return await probe.readCount == 4 && reading == 0 }
            #expect(await worker.statistics().suppressedReads == 10)
            await worker.close()
        } catch { await worker.close(); throw error }
    }

    @Test("delayed or repeated receipts cannot extend client retention or the original server lease", arguments: [false, true])
    func receiptDeadlineBound(serverExpiresFirst: Bool) async throws {
        let probe = Probe(), worker = V2AuthorPresentationDispatcher(configuration: try .init(mergeDelay: .zero), read: probe.read)
        let connection = UUID(), room = RoomID(uuid: UUID()), author = UserID(uuid: UUID()), view = UUID()
        do {
            await probe.setLifetime(serverExpiresFirst ? 0.15 : 5)
            let stream = try await worker.registerFixture(connectionID: connection, identity: identity(), send: probe.send)
            #expect(await worker.activateRoomFixture(connectionID: connection, roomID: room, viewID: view))
            #expect(await worker.replaceVisibleInterests(connectionID: connection,
                interests: try .init(streamID: stream, viewID: view, roomID: room, sequence: 1, userIDs: [author])))
            try await wait { await worker.statistics().deliveredFrames == 1 }
            let first = try #require(await probe.frames.first)
            await worker.acknowledge(connectionID: connection, receipt: try .init(streamID: stream, viewID: view,
                roomID: room, sequence: first.sequence, userIDs: [author], minimumRemainingMilliseconds: serverExpiresFirst ? 5_000 : 50))
            try await Task.sleep(for: .milliseconds(200))
            await worker.acknowledge(connectionID: connection, receipt: try .init(streamID: stream, viewID: view,
                roomID: room, sequence: first.sequence, userIDs: [author], minimumRemainingMilliseconds: 120_000))
            await worker.profileSourceCaughtUp()
            #expect(await worker.offer(connectionID: connection, roomID: room, authors: [author]))
            try await wait { await worker.statistics().deliveredFrames == 2 }
            #expect(await probe.readCount == 2)
            #expect(await probe.frames.last?.serverViewAgeMilliseconds ?? 0 >= 200)
            #expect(await worker.statistics().suppressedReads == 0)
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
                _ = try await worker.registerFixture(connectionID: connection, identity: identity(), send: probe.send)
                #expect(await worker.activateRoomFixture(connectionID: connection, roomID: room, viewID: UUID()))
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
            _ = try await worker.registerFixture(connectionID: connection, identity: identity(), send: probe.send)
            #expect(await worker.activateRoomFixture(connectionID: connection, roomID: room, viewID: UUID()))
            #expect(!(await worker.offer(connectionID: connection, roomID: room, authors: authors)))
            #expect(await worker.statistics().pendingBytes == 0)
            #expect(await probe.readCount == 0)
            await #expect(throws: V2ResourceProviderError.throttled(retryAfter: 1)) {
                _ = try await worker.registerFixture(connectionID: UUID(), identity: identity(), send: probe.send)
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
            _ = try await worker.registerFixture(connectionID: connection, identity: identity(), send: probe.send)
            #expect(!(await worker.offer(connectionID: connection, roomID: room, authors: [.init(uuid: UUID())])))
            #expect(await worker.activateRoomFixture(connectionID: connection, roomID: room, viewID: oldView))
            #expect(await worker.offer(connectionID: connection, roomID: room, authors: [.init(uuid: UUID())]))
            try await wait { await probe.readCount == 1 }
            await worker.deactivateView(connectionID: connection, viewID: oldView)
            #expect(await worker.activateRoomFixture(connectionID: connection, roomID: room, viewID: nextView))
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
            _ = try await worker.registerFixture(connectionID: connection, identity: identity(), send: probe.send)
            #expect(await worker.activateRoomFixture(connectionID: connection, roomID: room, viewID: UUID()))
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
            let stream = try await worker.registerFixture(connectionID: connection, identity: identity(), send: probe.send)
            #expect(await worker.activateRoomFixture(connectionID: connection, roomID: room, viewID: UUID()))
            #expect(await worker.offer(connectionID: connection, roomID: room, authors: [author]))
            try await wait { await worker.statistics().deliveredFrames == 1 }
            let first = try #require(await probe.frames.first)
            await worker.acknowledge(connectionID: connection, receipt: try .init(streamID: first.streamID,
                viewID: first.viewID, roomID: room, sequence: first.sequence, userIDs: [author]))
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
        let probe = Probe(holdWrites: true)
        let reader = authorPresentationFixtureBatch(probe.read)
        let worker = V2AuthorPresentationDispatcher(
            configuration: try .init(maximumReads: 1, maximumWrites: 1, mergeDelay: .zero), readBatch: { requests in
                await probe.recordReadBatch(requests.count)
                return try await reader(requests)
            })
        do {
            for _ in 0..<3 {
                let connection = UUID(), room = RoomID(uuid: UUID())
                _ = try await worker.registerFixture(connectionID: connection, identity: identity(), send: probe.send)
                #expect(await worker.activateRoomFixture(connectionID: connection, roomID: room, viewID: UUID()))
                #expect(await worker.offer(connectionID: connection, roomID: room, authors: [.init(uuid: UUID())]))
            }
            try await wait {
                let value = await worker.statistics()
                return await probe.readCount == 3 && value.reading == 0
            }
            let before = await worker.statistics()
            #expect(before.writing == 1 && before.outputBytes > 0)
            let timing = worker.readDiagnostics.snapshot()
            #expect(timing.stages[.dispatchQueue]?.calls == 3)
            let batches = await probe.readBatchSizes
            #expect(batches.reduce(0, +) == 3)
            #expect(timing.stages[.dispatchTask]?.calls == batches.count)
            #expect(timing.stages[.dispatchEncode]?.calls == 3)
            #expect(timing.stages[.dispatchWriteQueue]?.calls == 1)
            #expect(timing.stages[.dispatchWrite] == nil)
            let closeA = Task { await worker.close() }, closeB = Task { await worker.close() }
            try await wait { await worker.statistics().connections == 0 }
            #expect(await worker.statistics().writing == 1)
            #expect(await worker.statistics().outputBytes > 0)
            await probe.releaseWrites()
            await closeA.value; await closeB.value
            #expect(await worker.statistics().writing == 0)
            #expect(await worker.statistics().outputBytes == 0)
            #expect(await worker.statistics().deliveredFrames == 0)
            #expect(worker.readDiagnostics.snapshot().stages[.dispatchWrite]?.calls == 1)
        } catch { await probe.releaseWrites(); await worker.close(); throw error }
    }

    @Test("deferred visible interests refill as capacity returns without waiting for a publication poll")
    func visibleAdmissionProgress() async throws {
        let probe = Probe(holdReads: true), worker = V2AuthorPresentationDispatcher(configuration: try .init(
            maximumPendingKeys: 1, maximumPendingKeysPerConnection: 1, maximumReads: 1, maximumWrites: 1,
            mergeDelay: .zero), read: probe.read)
        let room = RoomID(uuid: UUID()), author = UserID(uuid: UUID())
        do {
            for index in 0..<3 {
                let connection = UUID(), view = UUID()
                let stream = try await worker.registerFixture(connectionID: connection, identity: identity(), send: probe.send)
                #expect(await worker.activateRoomFixture(connectionID: connection, roomID: room, viewID: view))
                #expect(await worker.replaceVisibleInterests(connectionID: connection, interests: try .init(
                    streamID: stream, viewID: view, roomID: room, sequence: 1, userIDs: [author])))
                if index == 0 { try await wait { await probe.readCount == 1 } }
            }
            let held = await worker.statistics()
            #expect(held.reading == 1 && held.pendingKeys == 1 && held.rejectedOffers > 0)
            await probe.releaseReads()
            // No runtime or explicit retryVisibleProfiles call drives this test.
            try await wait { await worker.statistics().deliveredFrames == 3 }
            #expect(await probe.readCount == 3)
            #expect(await worker.statistics().pendingKeys == 0)
            await worker.close()
        } catch { await probe.releaseReads(); await worker.close(); throw error }
    }

    @Test("unregister and replacement keep old non-cooperative reads charged and discard their results")
    func replacementGeneration() async throws {
        let probe = Probe(holdReads: true), worker = V2AuthorPresentationDispatcher(
            configuration: try .init(maximumReads: 1, mergeDelay: .zero), read: probe.read)
        let connection = UUID(), room = RoomID(uuid: UUID()), author = UserID(uuid: UUID())
        do {
            let old = try await worker.registerFixture(connectionID: connection, identity: identity(), send: probe.send)
            #expect(await worker.activateRoomFixture(connectionID: connection, roomID: room, viewID: UUID()))
            #expect(await worker.offer(connectionID: connection, roomID: room, authors: [author]))
            try await wait { await probe.readCount == 1 }
            await worker.unregister(connectionID: connection)
            let newIdentity = identity()
            let replacement = try await worker.registerFixture(connectionID: connection, identity: newIdentity, send: probe.send)
            #expect(await worker.activateRoomFixture(connectionID: connection, roomID: room, viewID: UUID()))
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
            _ = try await worker.registerFixture(connectionID: connection, identity: identity(), send: probe.send)
            #expect(await worker.activateRoomFixture(connectionID: connection, roomID: room, viewID: UUID()))
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
            _ = try await worker.registerFixture(connectionID: connection, identity: identity(), send: probe.send)
            #expect(await worker.activateRoomFixture(connectionID: connection, roomID: room, viewID: UUID()))
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

    @Test("fitting batches keep every author and oversized capabilities become bounded partial output", arguments: [false, true])
    func byteBudget(large: Bool) async throws {
        let probe = Probe(), worker = V2AuthorPresentationDispatcher(configuration: try .init(mergeDelay: .zero), read: probe.read)
        let connection = UUID(), room = RoomID(uuid: UUID())
        do {
            if large { await probe.setLargeAvatars() }
            _ = try await worker.registerFixture(connectionID: connection, identity: identity(), send: probe.send)
            #expect(await worker.activateRoomFixture(connectionID: connection, roomID: room, viewID: UUID()))
            #expect(await worker.offer(connectionID: connection, roomID: room, authors: (0..<16).map { _ in .init(uuid: UUID()) }))
            try await wait { await worker.statistics().deliveredFrames == 1 }
            let frame = try #require(await probe.frames.first)
            #expect(try frame.encoded().count <= V2AuthorPresentationDelta.maximumEncodedBytes)
            #expect(frame.batch.results.count == 16)
            #expect(frame.batch.results.contains { if case .retryable = $0 { true } else { false } } == large)
            #expect(frame.batch.results.contains { if case .presentation = $0 { true } else { false } })
            await worker.close()
        } catch { await worker.close(); throw error }
    }

    @Test("a small acknowledgement budget resends unretained authors without suppressing a denial")
    func hintBudgetExhaustion() async throws {
        let probe = Probe(), worker = V2AuthorPresentationDispatcher(
            configuration: try .init(maximumHintBytes: 1_024, mergeDelay: .zero), read: probe.read)
        let connection = UUID(), room = RoomID(uuid: UUID()), authors = (0..<2).map { _ in UserID(uuid: UUID()) }
        do {
            _ = try await worker.registerFixture(connectionID: connection, identity: identity(), send: probe.send)
            #expect(await worker.activateRoomFixture(connectionID: connection, roomID: room, viewID: UUID()))
            #expect(await worker.offer(connectionID: connection, roomID: room, authors: authors))
            try await wait { await worker.statistics().deliveredFrames == 1 }
            let first = try #require(await probe.frames.first)
            #expect(first.batch.results.count == 2)
            await worker.acknowledge(connectionID: connection, receipt: try .init(streamID: first.streamID,
                viewID: first.viewID, roomID: room, sequence: first.sequence, userIDs: authors))
            let retained = await worker.statistics().hintBytes
            #expect(retained > 0 && retained <= 1_024)
            #expect(await worker.offer(connectionID: connection, roomID: room, authors: authors))
            try await wait { await worker.statistics().deliveredFrames == 2 }
            let second = try #require(await probe.frames.last)
            #expect(second.batch.results.count == 1)
            #expect(Set(second.batch.results.map(\.key)).isSubset(of: Set(first.batch.results.map(\.key))))
            #expect(await worker.statistics().suppressedEntries == 1)
            #expect(await worker.statistics().hintBytes <= 1_024)
            await probe.setDenied()
            #expect(await worker.offer(connectionID: connection, roomID: room, authors: authors))
            try await wait { await worker.statistics().deliveredFrames == 3 }
            let denied = try #require(await probe.frames.last)
            #expect(denied.batch.results.count == 2)
            #expect(denied.batch.results.allSatisfy { if case .unavailable = $0 { true } else { false } })
            #expect(await worker.statistics().hintBytes == 0)
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
    var readBatchSizes: [Int] = []
    var requestSizes: [Int] = []
    var frames: [V2AuthorPresentationDelta] = []
    private var holdReads: Bool, holdWrites: Bool
    private var readWaiters: [CheckedContinuation<Void, Never>] = [], writeWaiters: [CheckedContinuation<Void, Never>] = []
    private var revision: UInt64 = 1
    private var denied = false, wrongRecipient = false, largeAvatars = false
    private var throttle: TimeInterval?
    private var lifetime: TimeInterval = 120
    private var receipt: (@Sendable (V2AuthorPresentationDelta) async -> Void)?
    private var writeAccepted = true

    init(holdReads: Bool = false, holdWrites: Bool = false) { self.holdReads = holdReads; self.holdWrites = holdWrites }
    func recordReadBatch(_ count: Int) { readBatchSizes.append(count) }
    func setRevision(_ value: UInt64) { revision = value }
    func setDenied() { denied = true }
    func setWrongRecipient() { wrongRecipient = true }
    func setThrottle(_ value: TimeInterval) { wrongRecipient = false; throttle = value }
    func setLargeAvatars() { largeAvatars = true }
    func setLifetime(_ value: TimeInterval) { lifetime = value }
    func setReceipt(_ value: (@Sendable (V2AuthorPresentationDelta) async -> Void)?) { receipt = value }
    func setWriteAccepted(_ value: Bool) { writeAccepted = value }
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
        await receipt?(frame)
        frames.append(frame); return writeAccepted
    }
}
