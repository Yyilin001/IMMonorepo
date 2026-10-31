import Foundation
import IMV2Core
import Testing
@testable import IMV2ServerApplication
@testable import IMV2ServerContracts

@Suite(.serialized)
struct V2AuthorPresentationBatchDispatchTests {
    @Test("busy output retires at its original deadline or page boundary", arguments: [false, true])
    func busyOutputRetirement(leavePage: Bool) async throws {
        let reader = DispatchBatchProbe(held: [], denials: true), sender = BusySocketProbe()
        let worker = V2AuthorPresentationDispatcher(configuration: try .init(mergeDelay: .zero,
            lifetime: .milliseconds(100)), readBatch: reader.read)
        let room = RoomID(uuid: UUID()), connection = UUID(), view = UUID()
        do {
            let stream = try await worker.register(connectionID: connection, identity: identity(), send: { bytes, deadline in
                await sender.send(bytes, deadline: deadline, healthy: false)
            })
            #expect(await worker.activateView(connectionID: connection,
                start: try .init(streamID: stream, viewID: view, messageRoomIDs: [room])))
            #expect(await worker.offer(connectionID: connection, roomID: room, authors: [.init(uuid: UUID())]))
            try await eventually { worker.readDiagnostics.snapshot().outcomes[.writeDeferred, default: 0] > 0 }
            if leavePage { await worker.deactivateView(connectionID: connection, viewID: view) }
            try await eventually {
                let stats = await worker.statistics()
                return stats.writing == 0 && stats.outputBytes == 0
            }
            #expect(await worker.statistics().deliveredFrames == 0)
            #expect(await reader.recipientReads == 1)
            #expect(await sender.reusedPreparedFrame)
            #expect(await sender.busyAttempts <= 5)
            await worker.close()
        } catch { await worker.close(); throw error }
    }

    @Test("a busy socket retries the prepared frame without re-reading or delaying a healthy socket")
    func busySocketReusesPreparedOutput() async throws {
        let reader = DispatchBatchProbe(held: [], denials: true), sender = BusySocketProbe()
        let worker = V2AuthorPresentationDispatcher(configuration: try .init(maximumWrites: 1,
            mergeDelay: .zero), readBatch: reader.read)
        let room = RoomID(uuid: UUID()), author = UserID(uuid: UUID()), busy = UUID(), healthy = UUID()
        do {
            for id in [busy, healthy] {
                let stream = try await worker.register(connectionID: id, identity: identity(), send: { bytes, deadline in
                    await sender.send(bytes, deadline: deadline, healthy: id == healthy)
                })
                #expect(await worker.activateView(connectionID: id,
                    start: try .init(streamID: stream, viewID: UUID(), messageRoomIDs: [room])))
            }
            #expect(await worker.offer(connectionID: busy, roomID: room, authors: [author]))
            try await eventually { await sender.busyAttempts > 0 }
            #expect(await worker.offer(connectionID: healthy, roomID: room, authors: [author]))
            try await eventually { await worker.statistics().deliveredFrames == 2 }
            #expect(await reader.recipientReads == 2)
            #expect(await sender.healthyDelivered)
            #expect(await sender.busyAttempts > 1)
            #expect(await sender.reusedPreparedFrame)
            #expect(await worker.statistics().outputBytes == 0)
            await worker.close()
        } catch { await worker.close(); throw error }
    }

    @Test("a later admission can shorten the next expiry while every read slot is occupied", arguments: [false, true])
    func laterAdmissionWithEarlierDeadline(updateExisting: Bool) async throws {
        let probe = DispatchBatchProbe(held: [0], denials: true)
        let deliveries = IndependentDeadlineProbe()
        let worker = V2AuthorPresentationDispatcher(configuration: try .init(maximumReads: 1,
            mergeDelay: .zero), readBatch: probe.read)
        let room = RoomID(uuid: UUID()), author = UserID(uuid: UUID())
        let seed = UUID(), fresh = UUID(), early = UUID(), view = UUID()
        do {
            for id in [seed, fresh, early] {
                _ = try await worker.registerFixture(connectionID: id, identity: identity(), send: { _, deadline in
                    await deliveries.deliver(id, deadline: deadline)
                })
                #expect(await worker.activateRoomFixture(connectionID: id, roomID: room, viewID: view))
            }
            #expect(await worker.offer(connectionID: seed, roomID: room, authors: [author]))
            try await eventually { await probe.batchSizes == [1] }
            #expect(await worker.offer(connectionID: fresh, roomID: room, authors: [author]))
            if updateExisting {
                #expect(await worker.offer(connectionID: early, roomID: room, authors: [author]))
            }
            #expect(await worker.offer(connectionID: early, roomID: room, viewID: view,
                authors: [.init(uuid: UUID())], deadline: .now + .milliseconds(40)))
            try await eventually { await worker.statistics().expiredJobs == 1 }
            #expect(await worker.statistics().pendingKeys == 1)
            #expect(await worker.statistics().reading == 1)
            #expect(await probe.batchSizes == [1])
            await probe.release()
            try await eventually { await deliveries.delivered == Set([seed, fresh]) }
            #expect(await probe.batchSizes == [1, 1])
            #expect(await worker.statistics().pendingKeys == 0)
            await worker.close()
        } catch { await probe.release(); await worker.close(); throw error }
    }

    @Test("visible work that expires before reading does not inherit a dependency retry delay", arguments: [false, true])
    func unreadQueueExpiryRecoversOnCapacity(retryable: Bool) async throws {
        let probe = DispatchBatchProbe(held: [0, 1], denials: !retryable)
        let deliveries = IndependentDeadlineProbe()
        let worker = V2AuthorPresentationDispatcher(configuration: try .init(maximumPendingKeys: 1,
            maximumPendingKeysPerConnection: 1, maximumReads: 1, mergeDelay: .zero,
            lifetime: .milliseconds(100)), readBatch: probe.read)
        let room = RoomID(uuid: UUID()), author = UserID(uuid: UUID())
        let seed = UUID(), queued = UUID(), visible = UUID(), view = UUID()
        var streams: [UUID: UUID] = [:]
        do {
            for id in [seed, queued, visible] {
                streams[id] = try await worker.registerFixture(connectionID: id, identity: identity(), send: { _, deadline in
                    await deliveries.deliver(id, deadline: deadline)
                })
                #expect(await worker.activateRoomFixture(connectionID: id, roomID: room, viewID: view))
            }
            #expect(await worker.offer(connectionID: seed, roomID: room, authors: [author]))
            try await eventually { await probe.batchSizes == [1] }
            #expect(await worker.offer(connectionID: queued, roomID: room, authors: [author]))
            #expect(await worker.replaceVisibleInterests(connectionID: visible, interests: try .init(
                streamID: #require(streams[visible]), viewID: view, roomID: room, sequence: 1, userIDs: [author])))
            #expect(await worker.statistics().pendingKeys == 1)
            await probe.release(0)
            try await eventually { await probe.batchSizes == [1, 1] }
            // This is deferred admission, after the original pending queue was
            // full. The reader still owns its slot even after cancellation.
            await worker.retryVisibleProfiles()
            #expect(await worker.statistics().pendingKeys == 1)
            try await eventually { await worker.statistics().expiredJobs >= 2 }
            #expect(await probe.batchSizes == [1, 1])
            #expect(await worker.statistics().reading == 1)
            let releasedAt = ContinuousClock.now
            await probe.release(1)
            // Exercise the normal recovery poll as well as completion-driven
            // draining. No dependency has yet been called for this viewer.
            while !(await deliveries.delivered.contains(visible)), .now < releasedAt + .milliseconds(300) {
                await worker.retryVisibleProfiles()
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(await deliveries.delivered.contains(visible))
            #expect(await probe.batchSizes == [1, 1, 1])
            #expect(await worker.statistics().pendingKeys == 0)
            // Once the dependency has actually run, both an unacknowledged
            // result and a transient failure retain their ordinary backoff.
            for _ in 0..<3 {
                await worker.retryVisibleProfiles()
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(await probe.batchSizes == [1, 1, 1])
            await worker.close()
        } catch { await probe.release(); await worker.close(); throw error }
    }

    @Test("one recipient deadline does not cancel a live batch peer or permit late delivery")
    func independentRecipientDeadlines() async throws {
        let probe = IndependentDeadlineProbe()
        let worker = V2AuthorPresentationDispatcher(configuration: try .init(maximumReads: 1,
            mergeDelay: .zero), readBatch: probe.read)
        let room = RoomID(uuid: UUID()), author = UserID(uuid: UUID())
        let seed = UUID(), early = UUID(), fresh = UUID(), view = UUID()
        do {
            for id in [seed, early, fresh] {
                _ = try await worker.registerFixture(connectionID: id, identity: identity(), send: { _, deadline in
                    await probe.deliver(id, deadline: deadline)
                })
                #expect(await worker.activateRoomFixture(connectionID: id, roomID: room, viewID: view))
            }
            #expect(await worker.offer(connectionID: seed, roomID: room, authors: [author]))
            try await eventually { await probe.batchSizes == [1] }
            let earlyDeadline = ContinuousClock.now + .milliseconds(150)
            #expect(await worker.offer(connectionID: early, roomID: room, viewID: view,
                authors: [author], deadline: earlyDeadline))
            #expect(await worker.offer(connectionID: fresh, roomID: room, authors: [author]))
            await probe.release()
            try await eventually {
                let stats = await worker.statistics()
                return await probe.batchSizes == [1, 2] && stats.reading == 0 && stats.writing == 0
            }
            #expect(await probe.delivered == Set([seed, fresh]))
            #expect(await probe.cancelledReads == 0)
            #expect(await probe.batchSizes == [1, 2])
            #expect(await worker.statistics().expiredJobs == 1)
            #expect(await worker.statistics().outputBytes == 0)
            await worker.close()
        } catch { await probe.release(); await worker.close(); throw error }
    }

    @Test("deferred visible viewers fill the next open batch without a second per-viewer merge window")
    func deferredViewersFillBatches() async throws {
        let probe = DispatchBatchProbe(denials: true)
        let worker = V2AuthorPresentationDispatcher(configuration: try .init(maximumReads: 1,
            mergeDelay: .milliseconds(5)), readBatch: probe.read)
        let room = RoomID(uuid: UUID()), author = UserID(uuid: UUID()), seed = UUID()
        do {
            _ = try await worker.registerFixture(connectionID: seed, identity: identity(), send: { _, _ in true })
            #expect(await worker.activateRoomFixture(connectionID: seed, roomID: room, viewID: UUID()))
            #expect(await worker.offer(connectionID: seed, roomID: room, authors: [author]))
            try await eventually { await probe.batchSizes == [1] }
            for _ in 0..<250 {
                let id = UUID(), view = UUID()
                let stream = try await worker.registerFixture(connectionID: id, identity: identity(), send: { bytes, _ in
                    guard let delta = try? V2AuthorPresentationDelta.decode(bytes),
                          let receipt = try? V2AuthorPresentationReceipt(streamID: delta.streamID,
                            viewID: delta.viewID, sequence: delta.sequence, keys: delta.batch.results.map(\.key),
                            minimumRemainingMilliseconds: 0) else { return false }
                    await worker.acknowledge(connectionID: id, receipt: receipt)
                    return true
                })
                #expect(await worker.activateRoomFixture(connectionID: id, roomID: room, viewID: view))
                #expect(await worker.replaceVisibleInterests(connectionID: id, interests: try .init(
                    streamID: stream, viewID: view, roomID: room, sequence: 1, userIDs: [author])))
            }
            #expect(await worker.statistics().pendingKeys == 128)
            #expect(await worker.statistics().visibleInterests == 250)
            await probe.release()
            try await eventually { await worker.statistics().deliveredFrames == 251 }
            #expect(await probe.batchSizes == [1, 100, 100, 50])
            #expect(await probe.recipientReads == 251)
            #expect(await worker.statistics().pendingKeys == 0)
            await worker.close()
        } catch { await probe.release(); await worker.close(); throw error }
    }

    @Test("author jobs pass their existing delivery deadline to the actual reader")
    func propagatesDeliveryDeadline() async throws {
        let probe = DispatchBatchProbe()
        let worker = V2AuthorPresentationDispatcher(configuration: try .init(mergeDelay: .zero), readBatch: probe.read)
        let connection = UUID(), room = RoomID(uuid: UUID()), started = ContinuousClock.now
        do {
            _ = try await worker.registerFixture(connectionID: connection, identity: identity(), send: { _, _ in true })
            #expect(await worker.activateRoomFixture(connectionID: connection, roomID: room, viewID: UUID()))
            #expect(await worker.offer(connectionID: connection, roomID: room, authors: [.init(uuid: UUID())]))
            try await eventually { await probe.recipientReads == 1 }
            let deadline = try #require(await probe.deadlines.first)
            #expect(deadline > started)
            #expect(deadline < started + .seconds(1))
        } catch { await probe.release(); await worker.close(); throw error }
        await probe.release(); await worker.close()
    }

    @Test("slow sockets bound the total recipients read ahead of delivery")
    func readAheadBackpressure() async throws {
        let probe = DispatchBatchProbe(held: [0, 1, 2, 3]), writes = DispatchWriteProbe()
        let worker = V2AuthorPresentationDispatcher(configuration: try .init(maximumPendingKeys: 1_024, mergeDelay: .zero), readBatch: probe.read)
        let room = RoomID(uuid: UUID()), author = UserID(uuid: UUID())
        do {
            for _ in 0..<201 {
                let connection = UUID()
                _ = try await worker.registerFixture(connectionID: connection, identity: identity(), send: writes.send)
                #expect(await worker.activateRoomFixture(connectionID: connection, roomID: room, viewID: UUID()))
                #expect(await worker.offer(connectionID: connection, roomID: room, authors: [author]))
            }
            await probe.release()
            try await eventually {
                let stats = await worker.statistics()
                return await probe.recipientReads >= 100 && stats.reading == 0 && stats.writing == 4
            }
            let readAhead = await probe.recipientReads
            #expect((100...200).contains(readAhead))
            #expect(await worker.statistics().pendingKeys == 201 - readAhead)
            await writes.release()
            try await eventually { await worker.statistics().deliveredFrames == 201 }
            #expect(await probe.recipientReads == 201)
            #expect(await worker.statistics().outputBytes == 0)
            await worker.close()
        } catch { await probe.release(); await writes.release(); await worker.close(); throw error }
    }

    @Test("a returned batch waiting for output stays charged and cancellation drains it")
    func returnedBatchOwnership() async throws {
        let probe = DispatchBatchProbe(), writes = DispatchWriteProbe()
        let worker = V2AuthorPresentationDispatcher(configuration: try .init(maximumReads: 1,
            maximumOutputBytes: 32_768, mergeDelay: .zero), readBatch: probe.read)
        let room = RoomID(uuid: UUID()), author = UserID(uuid: UUID()), seed = UUID()
        do {
            for connection in [seed] + (0..<100).map({ _ in UUID() }) {
                _ = try await worker.registerFixture(connectionID: connection, identity: identity(), send: writes.send)
                #expect(await worker.activateRoomFixture(connectionID: connection, roomID: room, viewID: UUID()))
                #expect(await worker.offer(connectionID: connection, roomID: room, authors: [author]))
            }
            // Retire the held seed without cancelling the next shared batch.
            await worker.unregister(connectionID: seed)
            await probe.release()
            try await eventually {
                let stats = await worker.statistics()
                return await probe.recipientReads == 101 && stats.reading == 1 && stats.writing == 1
            }
            #expect(await probe.batchSizes == [1, 100])
            let closing = Task { await worker.close() }
            try await eventually {
                let stats = await worker.statistics()
                return stats.connections == 0 && stats.reading == 0
            }
            #expect(await worker.statistics().writing == 1)
            #expect(await worker.statistics().outputBytes > 0)
            await writes.release(); await closing.value
            #expect(await worker.statistics().outputBytes == 0)
        } catch { await probe.release(); await writes.release(); await worker.close(); throw error }
    }

    @Test("replacing one page cannot cancel its batch peers or deliver its old result even with nonce reuse")
    func sharedReadPageReplacement() async throws {
        let probe = DispatchBatchProbe(held: [0, 1])
        let worker = V2AuthorPresentationDispatcher(configuration: try .init(maximumReads: 1, mergeDelay: .zero), readBatch: probe.read)
        let room = RoomID(uuid: UUID()), author = UserID(uuid: UUID()), seed = UUID(), a = UUID(), b = UUID(), nonce = UUID()
        do {
            for connection in [seed, a, b] {
                _ = try await worker.registerFixture(connectionID: connection, identity: identity(), send: { _, _ in true })
                #expect(await worker.activateRoomFixture(connectionID: connection, roomID: room, viewID: nonce))
            }
            #expect(await worker.offer(connectionID: seed, roomID: room, authors: [author]))
            try await eventually { await probe.batchSizes == [1] }
            for connection in [a, b] { #expect(await worker.offer(connectionID: connection, roomID: room, authors: [author])) }
            await probe.release(0)
            try await eventually { await probe.batchSizes == [1, 2] }
            await worker.deactivateView(connectionID: a, viewID: nonce)
            #expect(await worker.activateRoomFixture(connectionID: a, roomID: room, viewID: nonce))
            #expect(await worker.offer(connectionID: a, roomID: room, authors: [author]))
            #expect(await worker.statistics().reading == 1)
            await probe.release(1)
            try await eventually { await worker.statistics().deliveredFrames == 3 }
            #expect(await probe.batchSizes == [1, 2, 1])
            await worker.close()
        } catch { await probe.release(); await worker.close(); throw error }
    }

    @Test("one hundred queued recipients cross the batch service port in one call")
    func batchDispatch() async throws {
        let probe = DispatchBatchProbe()
        let worker = V2AuthorPresentationDispatcher(configuration: try .init(maximumReads: 1, mergeDelay: .zero), readBatch: probe.read)
        let room = RoomID(uuid: UUID()), author = UserID(uuid: UUID())
        do {
            let first = UUID()
            _ = try await worker.registerFixture(connectionID: first, identity: identity(), send: { _, _ in true })
            #expect(await worker.activateRoomFixture(connectionID: first, roomID: room, viewID: UUID()))
            #expect(await worker.offer(connectionID: first, roomID: room, authors: [author]))
            try await eventually { await probe.batchSizes == [1] }
            for _ in 0..<100 {
                let connection = UUID()
                _ = try await worker.registerFixture(connectionID: connection, identity: identity(), send: { _, _ in true })
                #expect(await worker.activateRoomFixture(connectionID: connection, roomID: room, viewID: UUID()))
                #expect(await worker.offer(connectionID: connection, roomID: room, authors: [author]))
            }
            #expect(await worker.statistics().pendingKeys == 100)
            await probe.release()
            try await eventually { await worker.statistics().deliveredFrames == 101 }
            #expect(await probe.batchSizes == [1, 100])
            #expect(await worker.statistics().pendingBytes == 0)
            await worker.close()
        } catch { await probe.release(); await worker.close(); throw error }
    }

    private func identity() -> V2AuthenticatedConnection {
        .init(userID: .init(uuid: UUID()), deviceID: .init(uuid: UUID()), capabilityProfile: "standard")
    }
    private func eventually(_ predicate: () async -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(3)
        while !(await predicate()) {
            guard .now < end else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

private actor BusySocketProbe {
    private(set) var busyAttempts = 0
    private(set) var healthyDelivered = false
    private(set) var reusedPreparedFrame = true
    private var first: (Data, ContinuousClock.Instant)?
    func send(_ bytes: Data, deadline: ContinuousClock.Instant, healthy: Bool) -> V2AuthorPresentationWriteResult {
        guard !Task.isCancelled, .now < deadline else { return .discarded }
        if healthy { healthyDelivered = true; return .enqueued }
        busyAttempts += 1
        if let first { reusedPreparedFrame = reusedPreparedFrame && first.0 == bytes && first.1 == deadline }
        else { first = (bytes, deadline) }
        return healthyDelivered ? .enqueued : .temporarilyUnavailable
    }
}

private actor IndependentDeadlineProbe {
    var batchSizes: [Int] = []
    var delivered: Set<UUID> = []
    var cancelledReads = 0
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false
    func release() { released = true; waiter?.resume(); waiter = nil }
    func read(_ inputs: [V2ProfilePresentationReadRequest]) async throws -> [Result<V2ProfilePresentationBatchResponse, any Error>] {
        batchSizes.append(inputs.count)
        if batchSizes.count == 1, !released { await withCheckedContinuation { waiter = $0 } }
        if inputs.count == 2 {
            let firstDeadline = try #require(inputs.map(\.deadline).min())
            do { try await ContinuousClock().sleep(until: firstDeadline + .milliseconds(30)) }
            catch { cancelledReads += 1; throw error }
        }
        try Task.checkCancellation()
        let now = Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
        return try inputs.map { input in
            .success(try .init(serverNowUnixMilliseconds: now, results: input.request.keys.map { .unavailable($0) }))
        }
    }
    func deliver(_ id: UUID, deadline: ContinuousClock.Instant) -> Bool {
        guard !Task.isCancelled, .now < deadline else { return false }
        delivered.insert(id); return true
    }
}

private actor DispatchBatchProbe {
    var batchSizes: [Int] = []
    var deadlines: [ContinuousClock.Instant] = []
    var recipientReads: Int { batchSizes.reduce(0, +) }
    private var held: Set<Int>
    private let denials: Bool
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
    init(held: Set<Int> = [0], denials: Bool = false) { self.held = held; self.denials = denials }
    func release(_ index: Int? = nil) {
        if let index { held.remove(index); waiters.removeValue(forKey: index)?.resume() }
        else { held.removeAll(); for value in waiters.values { value.resume() }; waiters.removeAll() }
    }
    func read(_ inputs: [V2ProfilePresentationReadRequest]) async throws -> [Result<V2ProfilePresentationBatchResponse, any Error>] {
        let index = batchSizes.count
        batchSizes.append(inputs.count)
        deadlines += inputs.map(\.deadline)
        if held.contains(index) { await withCheckedContinuation { waiters[index] = $0 } }
        let now = Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
        return try inputs.map { input in .success(try .init(serverNowUnixMilliseconds: now,
            results: input.request.keys.map { denials ? .unavailable($0) : .retryable($0) })) }
    }
}

private actor DispatchWriteProbe {
    private var held = true
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func send(_ bytes: Data, _ deadline: ContinuousClock.Instant) async -> Bool {
        if held { await withCheckedContinuation { waiters.append($0) } }
        return true
    }
    func release() {
        held = false
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}
