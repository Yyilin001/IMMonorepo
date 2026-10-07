import Foundation
import IMV2ActorContracts
import IMV2Core
import Testing
@testable import IMV2ActorRuntime

@Suite("Logical room references resolve through the owner and lease")
struct V2RoomDirectoryTests {
    @Test("forward pair retries preserve command identity and prior unknown outcomes", arguments: [false, true])
    func forwardPairRetryIdentity(unknownThenForbidden: Bool) async throws {
        let fixture = try Fixture()
        let pair = V2ActorForwardPairWire(actorUserID: .init(uuid: UUID()), operationID: .init(uuid: UUID()),
            source: try .init(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID()), revision: .init(1)),
            targetRoomID: fixture.room)
        let replies = ForwardRetryReplies(failures: unknownThenForbidden
            ? [.outcomeUnknown, .notAccepted(.forbidden)] : [.rolledBack(.staleActivation)])
        if unknownThenForbidden {
            await #expect(throws: V2RoomCallFailure.outcomeUnknown) {
                try await fixture.directory.callForwardPair(pair, deadline: .now + .seconds(2)) { token, pair, _ in
                    try await replies.respond(token, pair: pair)
                }
            }
        } else {
            let value = try await fixture.directory.callForwardPair(pair, deadline: .now + .seconds(2)) { token, pair, _ in
                try await replies.respond(token, pair: pair)
            }
            #expect(value.messageID != nil && value.targetRoomID == pair.targetRoomID)
            #expect(await fixture.directory.callMetricsSnapshot().locationInvalidations == 1)
        }
        let attempts = await replies.pairs
        #expect(attempts.count == 2 && attempts.allSatisfy { $0 == pair })
        #expect(await fixture.directory.quiesce(deadline: .now + .seconds(1)))
    }

    @Test("forward pair cancellation and deadline after unknown cannot claim not accepted", arguments: [false, true])
    func forwardPairUnknownCallerExit(cancelled: Bool) async throws {
        let fixture = try Fixture()
        await fixture.directory.remember(fixture.token)
        let pair = V2ActorForwardPairWire(actorUserID: .init(uuid: UUID()), operationID: .init(uuid: UUID()),
            source: try .init(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID()), revision: .init(1)),
            targetRoomID: fixture.room)
        let replies = ForwardRetryReplies(failures: [.outcomeUnknown, .outcomeUnknown, .outcomeUnknown])
        let task = Task {
            try await fixture.directory.callForwardPair(pair, deadline: .now + (cancelled ? .seconds(2) : .milliseconds(150))) { token, pair, _ in
                try await replies.respond(token, pair: pair)
            }
        }
        try await waitUntil { await !replies.pairs.isEmpty }
        if cancelled { task.cancel() }
        await #expect(throws: V2RoomCallFailure.outcomeUnknown) { try await task.value }
        #expect(await replies.pairs.allSatisfy { $0 == pair })
        #expect(await fixture.directory.quiesce(deadline: .now + .seconds(1)))
    }

    private actor ForwardRetryReplies {
        private var failures: [V2RoomCallFailure]
        private(set) var pairs: [V2ActorForwardPairWire] = []
        init(failures: [V2RoomCallFailure]) { self.failures = failures }
        func respond(_ token: V2RoomActivationToken, pair: V2ActorForwardPairWire) throws -> V2ActorForwardMessageResultWire {
            #expect(token.roomID == pair.targetRoomID)
            pairs.append(pair)
            if !failures.isEmpty { throw failures.removeFirst() }
            return .init(sourceMessageID: pair.source.messageID, targetRoomID: pair.targetRoomID,
                messageID: .init(uuid: UUID()), roomSequence: 1, errorCode: nil)
        }
    }
    @Test("cached and completion-ready viewers share one host RPC before a slow cold room", arguments: [false, true])
    func cachedRecoveryBatchUsesPhysicalGrouping(slowCold: Bool) async throws {
        let fixture = try Fixture(placement: slowCold)
        let gate = Gate()
        let slowRoom = RoomID(uuid: UUID())
        if slowCold { await fixture.owners.setGate(gate, room: slowRoom) }
        else { await fixture.directory.remember(fixture.token) }
        let users = [UserID(uuid: UUID()), UserID(uuid: UUID())]
        let healthyQueries = users.map { V2ActorRoomRecoveryItemQuery(roomID: fixture.room, actorUserID: $0, kind: .state) }
        let queries = slowCold ? [.init(roomID: slowRoom, actorUserID: users[0], kind: .state)] + healthyQueries : healthyQueries
        let replies = RecoveryReplies()
        let call = Task { try await fixture.directory.recoveryStates(queries, deadline: .now + .seconds(2)) { batch in
            await replies.append(batch)
        } }
        do {
            if slowCold { try await gate.waitForEntries(1) }
            try await waitUntil { await replies.containsRoom(fixture.room) }
            let healthy = await replies.forRoom(fixture.room)
            #expect(healthy.count == 2)
            #expect(healthy.map(\.query.actorUserID) == users)
            #expect(await fixture.transport.recoveryBatches == 1)
            if slowCold {
                #expect(await replies.containsRoom(slowRoom) == false)
                #expect(await fixture.directory.snapshot().active == 1)
                await gate.open()
            }
            let values = try await call.value
            #expect(values.count == queries.count)
            #expect(values.map(\.query) == queries)
            let observation = await fixture.directory.callMetricsSnapshot()
            #expect(observation.recoveryWarmItems == (slowCold ? 0 : 2))
            #expect(observation.recoveryColdItems == (slowCold ? 3 : 0))
            #expect(observation.recoveryHostCohorts == (slowCold ? 2 : 1))
            #expect(observation.recoveryHostItems == UInt64(queries.count))
            #expect(observation.recoveryStages[.hostCallerWait]?.completed == (slowCold ? 2 : 1))
            #expect(observation.recoveryStages[.hostCallerWait]?.itemsStarted == UInt64(queries.count))
            #expect(await fixture.transport.invoked.isEmpty)
            if !slowCold {
                #expect(await fixture.transport.lookups.isEmpty)
                #expect(await fixture.owners.calls == 0)
                #expect(await fixture.leases.locates == 0)
            } else {
                #expect(await fixture.owners.calls == 2)
                #expect(observation.recoveryStages[.coldCallerWait]?.completed == 2)
            }
            #expect(await fixture.directory.quiesce(deadline: .now + .seconds(1)))
        } catch {
            await gate.open()
            _ = await call.result
            _ = await fixture.directory.quiesce(deadline: .now + .seconds(1))
            throw error
        }
    }

    @Test("cold resolution starts while a cached host is still waiting")
    func coldResolutionDoesNotWaitForWarmHost() async throws {
        let fixture = try Fixture()
        let warmGate = Gate(), coldGate = Gate()
        let coldRoom = RoomID(uuid: UUID()), user = UserID(uuid: UUID())
        await fixture.directory.remember(fixture.token)
        await fixture.transport.configureRecoveryGate(warmGate, host: fixture.host)
        await fixture.owners.setGate(coldGate, room: coldRoom)
        let queries = [fixture.room, coldRoom].map {
            V2ActorRoomRecoveryItemQuery(roomID: $0, actorUserID: user, kind: .state)
        }
        let call = Task { try await fixture.directory.recoveryStates(queries, deadline: .now + .seconds(2)) { _ in } }
        do {
            try await warmGate.waitForEntries(1)
            try await coldGate.waitForEntries(1)
            await coldGate.open(); await warmGate.open()
            #expect(try await call.value.count == 2)
            #expect(await fixture.directory.quiesce(deadline: .now + .seconds(1)))
        } catch {
            await coldGate.open(); await warmGate.open()
            _ = await call.result
            throw error
        }
    }

    @Test("host cohorts share four actual slots and cancelled calls drain", arguments: [false, true])
    func recoveryHostWindowIsGlobal(cancel: Bool) async throws {
        let fixture = try Fixture(maximumCachedLocations: 8)
        let gate = Gate(), user = UserID(uuid: UUID())
        var queries: [V2ActorRoomRecoveryItemQuery] = []
        for _ in 0..<5 {
            let room = RoomID(uuid: UUID())
            let host = V2ActorHostIdentity(hostID: V2ActorHostID(uuid: UUID()), incarnationID: UUID())
            let token = V2RoomActivationToken(roomID: room, owner: fixture.owner,
                activationEpoch: try .init(1), host: host)
            await fixture.directory.remember(token)
            await fixture.transport.configureRecoveryGate(gate, host: host)
            queries.append(.init(roomID: room, actorUserID: user, kind: .state))
        }
        // Two independent callers must share the Directory budget.
        let firstQueries = Array(queries.prefix(3)), lastQueries = Array(queries.suffix(2))
        let first = Task { try await fixture.directory.recoveryStates(firstQueries, deadline: .now + .seconds(2)) { _ in } }
        let last = Task { try await fixture.directory.recoveryStates(lastQueries, deadline: .now + .seconds(2)) { _ in } }
        do {
            try await gate.waitForEntries(4)
            #expect(await fixture.transport.recoveryActual == 4)
            #expect(await fixture.transport.recoveryPeak == 4)
            if cancel { first.cancel(); last.cancel() }
            // Cancellation cannot free permits held by actual transport work.
            #expect(await fixture.transport.recoveryActual == 4)
            await gate.open()
            #expect(try await first.value.count == 3)
            #expect(try await last.value.count == 2)
            #expect(await fixture.transport.recoveryActual == 0)
            #expect(await fixture.transport.recoveryPeak == 4)
            #expect(await fixture.directory.quiesce(deadline: .now + .seconds(1)))
        } catch {
            await gate.open()
            _ = await first.result; _ = await last.result
            throw error
        }
    }

    @Test("last queued waiter releases its generation without cancelling an actual lookup", arguments: [false, true])
    func queuedResolutionDisposesLastWaiter(expires: Bool) async throws {
        let gate = Gate()
        let fixture = try Fixture(ownerGate: gate, maximumConcurrentResolutions: 1)
        let active = Task { try await fixture.directory.resolve(RoomID(uuid: UUID()), deadline: .now + .seconds(2)) }
        try await gate.waitForEntries(1)
        let queued = Task { try await fixture.directory.resolve(fixture.room,
            deadline: .now + (expires ? .milliseconds(80) : .seconds(2))) }
        try await waitUntil { await fixture.directory.snapshot().waiters == 2 }
        if !expires { queued.cancel() }
        await failure(.notAccepted(expires ? .deadlineExceeded : .cancelled)) { _ = try await queued.value }
        #expect(await fixture.directory.snapshot().pending == 1)
        #expect(await fixture.directory.snapshot().active == 1)
        #expect(await fixture.owners.calls == 1)
        // A successor uses a new generation; late removal from the old caller
        // must not delete it or run an extra lookup for the abandoned generation.
        let successor = Task { try await fixture.directory.resolve(fixture.room, deadline: .now + .seconds(2)) }
        try await waitUntil { await fixture.directory.snapshot().waiters == 2 }
        await gate.open()
        _ = try? await active.value
        #expect(try await successor.value == fixture.token)
        #expect(await fixture.owners.calls == 2)
        #expect(await fixture.directory.snapshot().pending == 0)
        #expect(await fixture.directory.quiesce(deadline: .now + .seconds(1)))
    }

    @Test("cached send and reads stay usable while the cold resolution queue is full", arguments: [false, true])
    func cachedSendBypassesFullResolutionQueue(read: Bool) async throws {
        let gate = Gate()
        let fixture = try Fixture(ownerGate: gate)
        await fixture.directory.remember(fixture.token)
        await fixture.transport.configureCached(available: true)
        let coldRooms = [RoomID(uuid: UUID()), RoomID(uuid: UUID())]
        let coldCalls = coldRooms.map { room in
            Task { try await fixture.directory.resolve(room, deadline: .now + .seconds(2)) }
        }
        try await gate.waitForEntries(2)
        #expect(await fixture.directory.snapshot().pending == 2)
        await failure(.notAccepted(.overloaded)) {
            _ = try await fixture.directory.resolve(RoomID(uuid: UUID()), deadline: .now + .seconds(1))
        }
        let user = UserID(uuid: UUID())
        let command = read ? V2RoomRequest.recovery(.init(roomID: fixture.room, actorUserID: user, kind: .state)) : try fixture.send(user: user)
        _ = try await fixture.directory.room(fixture.room).call(command, principal: .user(user),
            deadline: .now + .seconds(1))
        #expect(await fixture.transport.invoked == [command])
        #expect(await fixture.transport.lookups.isEmpty)
        #expect(await fixture.owners.calls == 2)
        #expect(await fixture.directory.snapshot().pending == 2)
        await fixture.directory.drain()
        await gate.open()
        for call in coldCalls { _ = try? await call.value }
        #expect(await fixture.directory.quiesce(deadline: .now + .seconds(1)))
    }

    @Test("cached operations preserve identity through unknown replies and drain actual hot calls")
    func cachedOperationAvoidsLocationWork() async throws {
        let fixture = try Fixture(existingLease: true)
        await fixture.directory.remember(fixture.token)
        await fixture.transport.configureCached(available: true, failures: [.outcomeUnknown])
        let user = UserID(uuid: UUID()), command = try fixture.send(user: user)
        _ = try await fixture.directory.room(fixture.room).call(command, principal: .user(user),
            deadline: .now + .seconds(2))
        guard case .messaging(.sendOperation(let operation)) = command else { throw TestFailure.timeout }
        let recovery = V2RoomRequest.messaging(.recoverSendOperation(try .init(identity: operation.identity,
            fingerprint: operation.fingerprint, domainFingerprint: operation.command.fingerprint, action: .query)))
        _ = try await fixture.directory.room(fixture.room).call(recovery, principal: .user(user),
            deadline: .now + .seconds(2))
        #expect(await fixture.transport.invoked == [command, command, recovery])
        #expect(await fixture.owners.calls == 0)
        #expect(await fixture.leases.locates == 0)
        #expect(await fixture.transport.lookups.isEmpty)
        #expect(await fixture.directory.snapshot().pending == 0)
        let metrics = await fixture.directory.callMetricsSnapshot()
        #expect(metrics.cachedCalls == 3 && metrics.cachedResponses == 2 && metrics.locationInvalidations == 0)
        let gate = Gate()
        await fixture.transport.configureCached(available: true, gate: gate)
        let active = Task { try await fixture.directory.room(fixture.room).call(command,
            principal: .user(user), deadline: .now + .seconds(2)) }
        try await gate.waitForEntries(1)
        #expect(await fixture.directory.quiesce(deadline: .now + .milliseconds(20)) == false)
        await gate.open()
        // A real successful reply remains successful after local drain begins.
        #expect(try await active.value == .recovery(.failure(.invalidRequest)))
        #expect(await fixture.directory.quiesce(deadline: .now + .seconds(1)))
    }

    @Test("a bounded hot RPC leaves the original deadline available for same-ID recovery")
    func cachedAttemptDeadlineLeavesRecoveryBudget() async throws {
        let fixture = try Fixture(existingLease: true, callTimeoutMilliseconds: 50)
        await fixture.directory.remember(fixture.token)
        await fixture.transport.configureCached(available: true)
        await fixture.transport.timeoutNextCachedCall()
        let user = UserID(uuid: UUID()), command = try fixture.send(user: user)
        _ = try await fixture.directory.room(fixture.room).call(command, principal: .user(user),
            deadline: .now + .seconds(2))
        #expect(await fixture.transport.invoked == [command, command])
        let budgets = await fixture.transport.cachedBudgets
        #expect(budgets.count == 2)
        #expect(budgets.allSatisfy { $0 > .zero && $0 <= .milliseconds(50) })
        #expect(await fixture.leases.locates == 0)
        #expect(await fixture.directory.callMetricsSnapshot().cachedResponses == 1)
    }

    @Test("a late cached failure cannot revoke a reinstalled identical token")
    func cachedCallRevisionPreventsABA() async throws {
        let fixture = try Fixture(existingLease: true)
        let gate = Gate()
        await fixture.directory.remember(fixture.token)
        await fixture.transport.configureCached(available: true, gate: gate,
            failures: [.notAccepted(.staleActivation)])
        let user = UserID(uuid: UUID()), command = try fixture.send(user: user)
        let old = Task { try await fixture.directory.room(fixture.room).call(command,
            principal: .user(user), deadline: .now + .seconds(2)) }
        try await gate.waitForEntries(1)
        await fixture.directory.remember(fixture.token) // same value, new installation
        await gate.open()
        _ = try await old.value
        #expect(await fixture.directory.callMetricsSnapshot().locationInvalidations == 0)
        #expect(await fixture.directory.snapshot().cached == 1)
        #expect(await fixture.transport.activations == 0)
    }

    @Test("demand recovery waits for the valid lease and reuses its original activation")
    func recoveryWaitsWithoutRepeatedLeaseReadsOrAcquire() async throws {
        let fixture = try Fixture(existingLease: true)
        await fixture.transport.setLookupAvailable(false)
        await fixture.transport.configureLookupFailures([.notAccepted(.deadlineExceeded)])
        let user = UserID(uuid: UUID()), command = try fixture.send(user: user)
        let recovering = Task { try await fixture.directory.room(fixture.room).call(command,
            principal: .user(user), deadline: .now + .seconds(2)) }
        try await waitUntil {
            let metrics = await fixture.directory.callMetricsSnapshot()
            return metrics.waitingForLeaseRooms == 1 && metrics.recoveryWaits >= 1
        }
        #expect(await fixture.leases.locates == 1)
        #expect(await fixture.transport.activations == 0)
        await fixture.transport.setLookupAvailable(true)
        _ = try await recovering.value
        #expect(await fixture.leases.locates == 1)
        #expect(await fixture.transport.activations == 0)
        #expect(await fixture.transport.invokedTokens == [fixture.token])
        #expect(await fixture.directory.callMetricsSnapshot().waitingForLeaseRooms == 0)
    }

    @Test("expired demand recovery reads authoritative absence before activating a new epoch")
    func expiredLeaseRecoveryKeepsOperationIdentity() async throws {
        let fixture = try Fixture(existingLease: true)
        let shortLease = try V2RoomActivationLease(token: fixture.token,
            databaseObservedAt: Date(timeIntervalSince1970: 1_000),
            expiresAt: Date(timeIntervalSince1970: 1_000.050))
        // The first authoritative observation is still valid; only the next
        // SQL observation reports absence. The old incarnation throws staleActivation,
        // and no local timer alone grants ownership.
        await fixture.leases.setLease(shortLease, removeAfterRead: true)
        await fixture.directory.remember(fixture.token)
        await fixture.transport.setLookupAvailable(false)
        let replacement = V2RoomActivationToken(roomID: fixture.room, owner: fixture.owner,
            activationEpoch: try .init(2), host: fixture.host)
        await fixture.transport.configureRecoveryActivation(replacement)
        let user = UserID(uuid: UUID()), command = try fixture.send(user: user)
        _ = try await fixture.directory.room(fixture.room).call(command, principal: .user(user),
            deadline: .now + .seconds(2))
        #expect(await fixture.leases.locates == 2)
        #expect(await fixture.transport.activations == 1)
        #expect(await fixture.transport.invoked == [command])
        #expect(await fixture.transport.invokedTokens == [replacement])
        #expect(await fixture.directory.callMetricsSnapshot().recoveryWaits >= 1)
        #expect(await fixture.directory.snapshot().active == 0)
    }

    @Test("a failed cache probe is not repeated before authoritative lease confirmation")
    func failedCacheProbeRunsOncePerRevision() async throws {
        let fixture = try Fixture(existingLease: true)
        await fixture.directory.remember(fixture.token)
        await fixture.transport.configureLookupFailures([.notAccepted(.notReady)])
        let user = UserID(uuid: UUID()), command = try fixture.send(user: user)
        _ = try await fixture.directory.room(fixture.room).call(command, principal: .user(user),
            deadline: .now + .seconds(2))
        // One cache probe, then one required authoritative lease confirmation.
        #expect(await fixture.transport.lookups.map(\.token) == [fixture.token, fixture.token])
        #expect(await fixture.leases.locates == 1)
        #expect(await fixture.transport.activations == 0)
        #expect(await fixture.transport.invoked == [command])
    }

    @Test("a failed old probe does not suppress a reinstalled identical cache token")
    func failedCacheProbeDoesNotSuppressNewRevision() async throws {
        let fixture = try Fixture(existingLease: true)
        let gate = Gate()
        await fixture.directory.remember(fixture.token)
        await fixture.transport.configureLookupFailures([.notAccepted(.notReady)], gate: gate)
        let user = UserID(uuid: UUID()), command = try fixture.send(user: user)
        let calling = Task { try await fixture.directory.room(fixture.room).call(command,
            principal: .user(user), deadline: .now + .seconds(2)) }
        try await gate.waitForEntries(1)
        await fixture.directory.remember(fixture.token) // same token, a new installation revision
        await gate.open()
        _ = try await calling.value
        #expect(await fixture.transport.lookups.map(\.token) == [fixture.token, fixture.token])
        #expect(await fixture.leases.locates == 0)
        #expect(await fixture.transport.activations == 0)
        #expect(await fixture.transport.invoked == [command])
    }

    @Test("cold placement distributes rooms and survives candidate reorder and host restart")
    func stableColdPlacement() async throws {
        let owner = try V2RoomDataOwner(shardID: "shard-a", epoch: 0)
        let identities = try (1...3).map { index in
            try V2ActorHostIdentity(hostID: V2ActorHostID(String(format: "00000000-0000-0000-0000-%012d", index)), incarnationID: UUID())
        }
        func directory(_ hosts: [V2ActorHostIdentity], capacity: Int = 2) throws -> V2RoomDirectory {
            let token = V2RoomActivationToken(roomID: try RoomID("seed-room"), owner: owner,
                activationEpoch: try .init(1), host: hosts[0])
            let transport = Transport(token: token, unreachable: false, activationFailure: nil, failures: [],
                failFirstLookup: false, localHintAvailable: false, localHintGate: nil, localFailures: [], placement: true)
            return V2RoomDirectory(owners: Owners(owner: owner, gate: nil, missing: false),
                leases: Leases(lease: nil), hosts: PlacementHosts(values: hosts.map {
                    .init(identity: $0, accessibleShardIDs: [owner.shardID], availableRooms: capacity, isHealthy: true)
                }), transport: transport, configuration: try .init())
        }
        let first = try directory(identities)
        let reordered = try directory(identities.reversed().map { .init(hostID: $0.hostID, incarnationID: UUID()) })
        var counts: [V2ActorHostID: Int] = [:]
        for index in 0..<256 {
            let room = try RoomID("placement-room-\(index)")
            let a = try await first.resolve(room, deadline: .now + .seconds(2))
            let b = try await reordered.resolve(room, deadline: .now + .seconds(2))
            #expect(a.host.hostID == b.host.hostID)
            counts[a.host.hostID, default: 0] += 1
        }
        #expect(counts.count == identities.count)
        #expect(counts.values.allSatisfy { (50...130).contains($0) })
        await first.drain(); await reordered.drain()
    }

    @Test("a valid lease wins over higher-capacity rendezvous candidates")
    func placementPreservesLease() async throws {
        let fixture = try Fixture(existingLease: true)
        let other = V2ActorHostIdentity(hostID: V2ActorHostID(uuid: UUID()), incarnationID: UUID())
        let directory = V2RoomDirectory(owners: fixture.owners, leases: fixture.leases,
            hosts: PlacementHosts(values: [.init(identity: other, accessibleShardIDs: [fixture.owner.shardID],
                availableRooms: 100, isHealthy: true)]), transport: fixture.transport, configuration: try .init())
        let result = try await directory.resolve(fixture.room, deadline: .now + .seconds(2))
        #expect(result == fixture.token)
        #expect(await fixture.transport.activations == 0)
        await directory.drain()
    }

    @Test("concurrent callers share one bounded resolution", arguments: [2, 100])
    func singleflight(callers: Int) async throws {
        let gate = Gate()
        let fixture = try Fixture(ownerGate: gate, maximumWaiters: max(3, callers))
        let first = Task { try await fixture.directory.resolve(fixture.room, deadline: .now + .seconds(2)) }
        try await gate.waitForEntries(1)
        let others = (1..<callers).map { _ in
            Task { try await fixture.directory.resolve(fixture.room, deadline: .now + .seconds(2)) }
        }
        do {
            try await waitUntil { await fixture.directory.snapshot().waiters == callers }
            await gate.open()
            #expect(try await first.value == fixture.token)
            for caller in others { #expect(try await caller.value == fixture.token) }
            #expect(await fixture.owners.calls == 1)
            #expect(await fixture.leases.locates == 1)
            #expect(await fixture.transport.activations == 1)
        } catch {
            await gate.open()
            _ = try? await first.value
            for caller in others { _ = try? await caller.value }
            throw error
        }
    }

    @Test("drain rejects waiters while quiesce retains the actual owner lookup")
    func drainTracksResolution() async throws {
        let gate = Gate()
        let fixture = try Fixture(ownerGate: gate, maximumConcurrentResolutions: 1)
        let call = Task { try await fixture.directory.resolve(fixture.room, deadline: .now + .seconds(2)) }
        var successor: Task<V2RoomActivationToken, any Error>?
        do {
            try await gate.waitForEntries(1)
            let query = V2ActorRoomRecoveryItemQuery(roomID: fixture.room, actorUserID: UserID(uuid: UUID()), kind: .state)
            let queuedRoom = RoomID(uuid: UUID())
            let queuedQuery = V2ActorRoomRecoveryItemQuery(roomID: queuedRoom, actorUserID: query.actorUserID, kind: .state)
            let recovery = Task { try await fixture.directory.recoveryStates([query, queuedQuery], deadline: .now + .seconds(2)) { _ in } }
            try await waitUntil { await fixture.directory.snapshot().waiters == 3 }
            #expect(await fixture.directory.snapshot().pending == 2)
            recovery.cancel()
            _ = try await recovery.value
            let held = await fixture.directory.callMetricsSnapshot()
            #expect(held.recoveryStages[.coldCallerWait]?.active == 0)
            #expect(held.recoveryStages[.coldCallerWait]?.completed == 2)
            #expect(await fixture.directory.snapshot().pending == 1)
            // Re-register the abandoned queued room under a successor generation.
            // The old batch cancellation must not remove this ordinary waiter.
            successor = Task { try await fixture.directory.resolve(queuedRoom, deadline: .now + .seconds(2)) }
            try await waitUntil { await fixture.directory.snapshot().waiters == 2 }
            #expect(await fixture.directory.snapshot().pending == 2)
            #expect(held.recoveryStages[.actualResolution]?.active == 1)
            #expect(held.recoveryStages[.actualResolution]?.completed == 0)
            #expect(await fixture.directory.quiesce(deadline: .now + .milliseconds(20)) == false)
            await failure(.notAccepted(.retired)) { _ = try await call.value }
            if let successor { await failure(.notAccepted(.retired)) { _ = try await successor.value } }
            #expect(await fixture.directory.snapshot().active == 1)
            await gate.open()
            #expect(await fixture.directory.quiesce(deadline: .now + .seconds(1)))
            #expect(await fixture.directory.snapshot().active == 0)
            let settled = await fixture.directory.callMetricsSnapshot()
            #expect(settled.recoveryStages[.actualResolution]?.active == 0)
            #expect(settled.recoveryStages[.actualResolution]?.completed == 1)
            #expect(settled.recoveryStages[.actualResolution]?.oldestMilliseconds == 0)
        } catch {
            await gate.open()
            _ = await call.result
            if let successor { _ = await successor.result }
            _ = await fixture.directory.quiesce(deadline: .now + .seconds(1))
            throw error
        }
    }

    @Test("a valid but unreachable lease never causes another acquire")
    func unreachableLease() async throws {
        let fixture = try Fixture(existingLease: true, unreachable: true)
        await failure(.notAccepted(.unavailable)) {
            _ = try await fixture.directory.resolve(fixture.room, deadline: .now + .seconds(1))
        }
        #expect(await fixture.transport.activations == 0)
        #expect(await fixture.leases.locates == 1)
    }

    @Test("unknown activation remains unknown after an empty locate")
    func unknownActivation() async throws {
        let fixture = try Fixture(activationFailure: .outcomeUnknown)
        await failure(.outcomeUnknown) {
            _ = try await fixture.directory.resolve(fixture.room, deadline: .now + .seconds(1))
        }
        #expect(await fixture.transport.activations == 1)
        #expect(await fixture.leases.locates == 2)
    }

    @Test("unknown owner rejects without activating an empty room")
    func unknownRoom() async throws {
        let fixture = try Fixture(missingOwner: true)
        await failure(.notAccepted(.notFound)) {
            _ = try await fixture.directory.resolve(fixture.room, deadline: .now + .seconds(1))
        }
        #expect(await fixture.leases.locates == 0)
        #expect(await fixture.transport.activations == 0)
    }

    @Test("a stale activation response cannot overwrite a newer cached epoch")
    func staleCache() async throws {
        let fixture = try Fixture()
        let newer = V2RoomActivationToken(
            roomID: fixture.room, owner: fixture.owner,
            activationEpoch: try .init(2), host: fixture.host
        )
        await fixture.directory.remember(newer)
        await fixture.directory.remember(fixture.token)
        let observed = try await fixture.directory.resolve(fixture.room, deadline: .now + .seconds(1))
        #expect(observed == newer)
        #expect(await fixture.transport.activations == 0)
    }

    @Test("a stale cached lookup has a short locator budget and returns to the owner lease")
    func staleLookupUsesAuthoritativeLease() async throws {
        let fixture = try Fixture(existingLease: true, failFirstLookup: true)
        let replacement = V2RoomActivationToken(
            roomID: fixture.room, owner: fixture.owner,
            activationEpoch: try .init(2), host: fixture.host
        )
        await fixture.directory.remember(fixture.token)
        await fixture.leases.setLease(try .init(
            token: replacement, databaseObservedAt: Date(timeIntervalSince1970: 1_001),
            expiresAt: Date(timeIntervalSince1970: 1_031)
        ))

        #expect(try await fixture.directory.resolve(fixture.room, deadline: .now + .seconds(12))
                == replacement)
        #expect(await fixture.leases.locates == 1)
        #expect(await fixture.transport.activations == 0)
        let lookups = await fixture.transport.lookups
        #expect(lookups.map(\.token) == [fixture.token, replacement])
        #expect(lookups.allSatisfy { $0.budget > .zero && $0.budget <= .seconds(3) })
    }

    @Test("a shorter configured call timeout also bounds the locator hop")
    func shorterCallTimeout() async throws {
        let fixture = try Fixture(existingLease: true, callTimeoutMilliseconds: 2_000)
        #expect(try await fixture.directory.resolve(fixture.room, deadline: .now + .seconds(5))
                == fixture.token)
        let lookups = await fixture.transport.lookups
        #expect(lookups.count == 1)
        #expect(lookups.allSatisfy { $0.budget > .zero && $0.budget <= .seconds(2) })
    }

    @Test("unknown durable result retries the same typed operation within its bound")
    func stableRetry() async throws {
        let fixture = try Fixture(existingLease: true, invokeFailures: [.outcomeUnknown])
        let user = UserID(uuid: UUID())
        let command = V2RoomRequest.messaging(.sendOperation(try .init(command: .init(
            roomID: fixture.room, senderUserID: user,
            clientMessageID: ClientMessageID(uuid: UUID()), text: "same operation",
            limits: .init(maxUTF8Bytes: 64)
        ), firstSubmissionDeadlineMilliseconds: 1_750_000_060_000)))
        let result = try await fixture.directory.room(fixture.room).call(
            command, principal: .user(user), deadline: .now + .seconds(2)
        )
        #expect(result == .recovery(.failure(.invalidRequest)))
        let requests = await fixture.transport.invoked
        #expect(requests == [command, command])
        #expect(await fixture.leases.locates == 1)
    }

    @Test("repeatable local calls use a hint while public resolution remains physical")
    func localHintOnlyForRepeatableCall() async throws {
        let fixture = try Fixture(existingLease: true, localHintAvailable: true)
        let user = UserID(uuid: UUID())
        let command = try fixture.send(user: user)
        #expect(try await fixture.directory.resolve(fixture.room, deadline: .now + .seconds(2)) == fixture.token)
        let initialLookups = await fixture.transport.lookups.count
        #expect(initialLookups == 1)
        _ = try await fixture.directory.room(fixture.room).call(command, principal: .user(user),
            deadline: .now + .seconds(2))
        #expect(await fixture.transport.localInvocations == 1)
        #expect(await fixture.transport.lookups.count == initialLookups)
        #expect(await fixture.owners.calls == 1)
        _ = try await fixture.directory.room(fixture.room).call(
            .recovery(.init(roomID: fixture.room, actorUserID: user, kind: .state)),
            principal: .user(user), deadline: .now + .seconds(2))
        #expect(await fixture.transport.localInvocations == 2)
        #expect(try await fixture.directory.resolve(fixture.room, deadline: .now + .seconds(2)) == fixture.token)
        #expect(await fixture.transport.lookups.count == initialLookups + 1)
        let grouped = try await fixture.directory.groupedRead(
            [.recovery(.init(roomID: fixture.room, actorUserID: user, kind: .state))],
            principal: .user(user), deadline: .now + .seconds(2)) { _, _, items, _, _ in
                items.map { _ in .recovery(.failure(.invalidRequest)) }
            }
        #expect(grouped == [.recovery(.failure(.invalidRequest))])
        #expect(await fixture.transport.lookups.count == initialLookups + 2)
        #expect(await fixture.transport.localInvocations == 2)
    }

    @Test("a strict waiter stays strict after cancellation while the local predicate waits")
    func strictWaiterIsSticky() async throws {
        let gate = Gate()
        let fixture = try Fixture(existingLease: true, localHintAvailable: true, localHintGate: gate)
        await fixture.directory.remember(fixture.token)
        let user = UserID(uuid: UUID())
        let weak = Task { try await fixture.directory.room(fixture.room).call(
            fixture.send(user: user), principal: .user(user), deadline: .now + .seconds(3)) }
        try await gate.waitForEntries(1)
        let strict = Task { try await fixture.directory.resolve(fixture.room, deadline: .now + .seconds(3)) }
        try await waitUntil { await fixture.directory.snapshot().waiters == 2 }
        strict.cancel()
        await failure(.notAccepted(.cancelled)) { _ = try await strict.value }
        await gate.open()
        _ = try await weak.value
        #expect(await fixture.transport.lookups.count == 1)
        #expect(await fixture.transport.localInvocations == 0)
    }

    @Test("a replaced cache during the predicate is strictly confirmed")
    func cacheReplacementWhileHintSuspended() async throws {
        let gate = Gate()
        let fixture = try Fixture(existingLease: true, localHintAvailable: true, localHintGate: gate)
        await fixture.directory.remember(fixture.token)
        let user = UserID(uuid: UUID())
        let weak = Task { try await fixture.directory.room(fixture.room).call(
            fixture.send(user: user), principal: .user(user), deadline: .now + .seconds(3)) }
        try await gate.waitForEntries(1)
        let newer = V2RoomActivationToken(roomID: fixture.room, owner: fixture.owner,
            activationEpoch: try .init(2), host: fixture.host)
        await fixture.directory.remember(newer)
        await fixture.leases.setLease(try .init(token: newer,
            databaseObservedAt: Date(timeIntervalSince1970: 1_001),
            expiresAt: Date(timeIntervalSince1970: 1_031)))
        await gate.open()
        _ = try await weak.value
        #expect(await fixture.transport.localInvocations == 0)
        #expect(await fixture.transport.lookups.map(\.token) == [newer])
        #expect(await fixture.transport.invokedTokens == [newer])
    }

    @Test("a local rejection relocates one durable operation without a second acquire")
    func staleLocalHintRelocates() async throws {
        let fixture = try Fixture(existingLease: true, localHintAvailable: true,
            localFailures: [.notAccepted(.notReady)])
        await fixture.directory.remember(fixture.token)
        let newer = V2RoomActivationToken(roomID: fixture.room, owner: fixture.owner,
            activationEpoch: try .init(2), host: fixture.host)
        await fixture.leases.setLease(try .init(token: newer,
            databaseObservedAt: Date(timeIntervalSince1970: 1_001),
            expiresAt: Date(timeIntervalSince1970: 1_031)))
        let user = UserID(uuid: UUID())
        let command = try fixture.send(user: user)
        _ = try await fixture.directory.room(fixture.room).call(command,
            principal: .user(user), deadline: .now + .seconds(3))
        #expect(await fixture.transport.localInvocations == 1)
        #expect(await fixture.transport.invoked == [command, command])
        #expect(await fixture.transport.invokedTokens == [newer])
        #expect(await fixture.transport.activations == 0)
    }

    @Test("unknown hinted result retries only the same durable operation")
    func unknownLocalHintUsesExistingRetry() async throws {
        let fixture = try Fixture(existingLease: true, localHintAvailable: true,
            localFailures: [.outcomeUnknown])
        await fixture.directory.remember(fixture.token)
        let user = UserID(uuid: UUID())
        let command = try fixture.send(user: user)
        _ = try await fixture.directory.room(fixture.room).call(command,
            principal: .user(user), deadline: .now + .seconds(3))
        #expect(await fixture.transport.localInvocations == 2)
        #expect(await fixture.transport.invoked == [command, command])
        #expect(await fixture.transport.lookups.count == 0)
    }

    @Test("a no-auto-retry request remains strict and does not replay unknown")
    func noAutomaticRetryIsStrict() async throws {
        let fixture = try Fixture(existingLease: true, invokeFailures: [.outcomeUnknown],
            localHintAvailable: true)
        await fixture.directory.remember(fixture.token)
        let command = V2RoomRequest.maintenance(.trimLog(.init(roomID: fixture.room,
            mode: .window, windowSeconds: 86_400)))
        await failure(.outcomeUnknown) {
            _ = try await fixture.directory.room(fixture.room).call(command,
                principal: .service, deadline: .now + .seconds(3))
        }
        #expect(await fixture.transport.localInvocations == 0)
        #expect(await fixture.transport.invoked == [command])
        #expect(await fixture.transport.lookups.count == 1)
    }

    @Test("bounded location cache evicts old rooms")
    func cacheBound() async throws {
        let fixture = try Fixture(maximumCachedLocations: 2)
        for _ in 0..<3 {
            let room = RoomID(uuid: UUID())
            await fixture.directory.remember(.init(
                roomID: room, owner: fixture.owner,
                activationEpoch: try .init(1), host: fixture.host
            ))
        }
        #expect(await fixture.directory.snapshot().cached == 2)
    }

    private func failure(_ expected: V2RoomCallFailure,
                         action: () async throws -> Void) async {
        do { try await action(); Issue.record("unexpected success") }
        catch { #expect(error as? V2RoomCallFailure == expected) }
    }

    private func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw TestFailure.timeout }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private enum TestFailure: Error { case timeout }

    private struct Fixture {
        let room = RoomID(uuid: UUID())
        let owner: V2RoomDataOwner
        let host: V2ActorHostIdentity
        let token: V2RoomActivationToken
        let owners: Owners
        let leases: Leases
        let transport: Transport
        let directory: V2RoomDirectory

        func send(user: UserID) throws -> V2RoomRequest {
            .messaging(.sendOperation(try .init(command: .init(roomID: room, senderUserID: user,
                clientMessageID: .init(uuid: UUID()), text: "local hint", limits: .init(maxUTF8Bytes: 64)),
                firstSubmissionDeadlineMilliseconds: 1_750_000_060_000)))
        }

        init(ownerGate: Gate? = nil, existingLease: Bool = false,
             unreachable: Bool = false, missingOwner: Bool = false,
             failFirstLookup: Bool = false,
             activationFailure: V2RoomCallFailure? = nil,
             invokeFailures: [V2RoomCallFailure] = [],
             localHintAvailable: Bool = false, localHintGate: Gate? = nil,
             localFailures: [V2RoomCallFailure] = [],
             maximumCachedLocations: Int = 2,
             callTimeoutMilliseconds: Int64 = 30_000,
             maximumConcurrentResolutions: Int = 2, placement: Bool = false, maximumWaiters: Int = 3) throws {
            owner = try .init(shardID: "shard-a", epoch: 0)
            host = .init(hostID: V2ActorHostID(uuid: UUID()), incarnationID: UUID())
            token = .init(roomID: room, owner: owner, activationEpoch: try .init(1), host: host)
            owners = Owners(owner: owner, gate: ownerGate, missing: missingOwner)
            let lease = try V2RoomActivationLease(
                token: token, databaseObservedAt: Date(timeIntervalSince1970: 1_000),
                expiresAt: Date(timeIntervalSince1970: 1_030)
            )
            leases = Leases(lease: existingLease ? lease : nil)
            transport = Transport(token: token, unreachable: unreachable,
                                  activationFailure: activationFailure, failures: invokeFailures,
                                  failFirstLookup: failFirstLookup,
                                  localHintAvailable: localHintAvailable, localHintGate: localHintGate,
                                  localFailures: localFailures, placement: placement)
            let provider = Hosts(host: host)
            let configuration = try V2RoomRuntimeConfiguration(
                maximumActiveRooms: 2, maximumConcurrentRestores: 1,
                maximumActivationWaitersPerRoom: maximumWaiters, maximumPendingActivations: 2,
                maximumActivationWaitersPerHost: maximumWaiters, maximumConcurrentResolutions: maximumConcurrentResolutions,
                maximumCachedLocations: maximumCachedLocations, maximumConcurrentReservations: 1,
                transactionTimeoutMilliseconds: min(10_000, callTimeoutMilliseconds),
                callTimeoutMilliseconds: callTimeoutMilliseconds,
                reservationTimeoutMilliseconds: min(15_000, callTimeoutMilliseconds)
            )
            directory = .init(owners: owners, leases: leases, hosts: provider,
                              transport: transport, configuration: configuration)
        }
    }

    private actor Owners: V2RoomDataOwnerResolving {
        let owner: V2RoomDataOwner
        let gate: Gate?
        let missing: Bool
        var calls = 0
        private var roomGates: [RoomID: Gate] = [:]
        func setGate(_ gate: Gate, room: RoomID) { roomGates[room] = gate }
        init(owner: V2RoomDataOwner, gate: Gate?, missing: Bool) {
            self.owner = owner; self.gate = gate; self.missing = missing
        }
        func owner(for roomID: RoomID) async throws -> V2RoomDataOwner {
            calls += 1
            if let gate = roomGates[roomID] ?? gate { await gate.wait() }
            if missing { throw V2RoomActivationLeaseError.roomNotFound }
            return owner
        }
    }

    private actor Leases: V2RoomActivationLeaseStore {
        var lease: V2RoomActivationLease?
        var locates = 0
        var removeAfterRead = false
        init(lease: V2RoomActivationLease?) { self.lease = lease }
        func setLease(_ value: V2RoomActivationLease, removeAfterRead: Bool = false) {
            lease = value; self.removeAfterRead = removeAfterRead
        }
        func locate(roomID: RoomID, owner: V2RoomDataOwner) async throws -> V2RoomActivationLease? {
            locates += 1
            let observed = lease
            if removeAfterRead { lease = nil; removeAfterRead = false }
            return observed
        }
        func acquire(roomID: RoomID, owner: V2RoomDataOwner, host: V2ActorHostIdentity,
                     duration: V2ActorMilliseconds) async throws -> V2RoomActivationAcquisition {
            throw V2RoomActivationLeaseError.roomNotFound
        }
        func renew(token: V2RoomActivationToken, duration: V2ActorMilliseconds) async throws -> V2RoomActivationLease {
            throw V2RoomActivationLeaseError.activationChanged
        }
        func release(token: V2RoomActivationToken) async throws -> Bool { false }
    }

    private struct PlacementHosts: V2RoomHostDiscovering {
        let values: [V2RoomHostCandidate]
        func candidates(for owner: V2RoomDataOwner) async throws -> [V2RoomHostCandidate] { values }
    }

    private struct Hosts: V2RoomHostDiscovering {
        let host: V2ActorHostIdentity
        func candidates(for owner: V2RoomDataOwner) async throws -> [V2RoomHostCandidate] {
            [.init(identity: host, accessibleShardIDs: [owner.shardID], availableRooms: 2, isHealthy: true)]
        }
    }

    private actor Transport: V2RoomClientTransport {
        let token: V2RoomActivationToken
        let unreachable: Bool
        let activationFailure: V2RoomCallFailure?
        var failures: [V2RoomCallFailure]
        var failFirstLookup: Bool
        var activations = 0
        var invoked: [V2RoomRequest] = []
        var lookups: [(token: V2RoomActivationToken, budget: Duration)] = []
        var invokedTokens: [V2RoomActivationToken] = []
        var localHintAvailable: Bool
        let localHintGate: Gate?
        var localFailures: [V2RoomCallFailure]
        var localInvocations = 0
        let placement: Bool
        var cachedAvailable = false
        var cachedGate: Gate?
        var cachedFailures: [V2RoomCallFailure] = []
        var cachedBudgets: [Duration] = []
        private var cachedTimeoutPending = false
        func timeoutNextCachedCall() { cachedTimeoutPending = true }
        var rejectLookups = false
        private var lookupFailures: [V2RoomCallFailure] = []
        private var lookupGate: Gate?
        func configureLookupFailures(_ failures: [V2RoomCallFailure], gate: Gate? = nil) {
            lookupFailures = failures; lookupGate = gate
        }
        func configureCached(available: Bool, gate: Gate? = nil, failures: [V2RoomCallFailure] = []) {
            cachedAvailable = available; cachedGate = gate; cachedFailures = failures
        }
        private var recoveryActivation: V2RoomActivationToken?
        func configureRecoveryActivation(_ token: V2RoomActivationToken) { recoveryActivation = token }
        func setLookupAvailable(_ available: Bool) { rejectLookups = !available }
        func tryInvokeCached(_ token: V2RoomActivationToken, request: V2RoomRequest,
                             principal: V2RoomClientPrincipal,
                             deadline: ContinuousClock.Instant) async throws -> V2CachedRoomCallResult {
            guard cachedAvailable else { return .cacheMiss }
            invoked.append(request); invokedTokens.append(token)
            cachedBudgets.append(ContinuousClock.now.duration(to: deadline))
            if cachedTimeoutPending {
                cachedTimeoutPending = false
                try await ContinuousClock().sleep(until: deadline)
                throw V2RoomCallFailure.outcomeUnknown
            }
            let failure = cachedFailures.isEmpty ? nil : cachedFailures.removeFirst()
            if let cachedGate { await cachedGate.wait() }
            if let failure { throw failure }
            return .response(.recovery(.failure(.invalidRequest)))
        }
        init(token: V2RoomActivationToken, unreachable: Bool,
             activationFailure: V2RoomCallFailure?, failures: [V2RoomCallFailure],
             failFirstLookup: Bool, localHintAvailable: Bool, localHintGate: Gate?,
             localFailures: [V2RoomCallFailure], placement: Bool = false) {
            self.placement = placement
            self.token = token; self.unreachable = unreachable
            self.activationFailure = activationFailure; self.failures = failures
            self.failFirstLookup = failFirstLookup
            self.localHintAvailable = localHintAvailable
            self.localHintGate = localHintGate
            self.localFailures = localFailures
        }
        func activate(on host: V2ActorHostIdentity, roomID: RoomID, owner: V2RoomDataOwner,
                      deadline: ContinuousClock.Instant) async throws -> V2RoomActivationResolution {
            activations += 1
            if let activationFailure { throw activationFailure }
            if let recoveryActivation {
                rejectLookups = false
                return .ready(recoveryActivation)
            }
            if placement {
                return .ready(.init(roomID: roomID, owner: owner, activationEpoch: token.activationEpoch, host: host))
            }
            return .ready(token)
        }
        func lookup(_ token: V2RoomActivationToken, deadline: ContinuousClock.Instant) async throws -> Bool {
            lookups.append((token, ContinuousClock.now.duration(to: deadline)))
            let injectedFailure = lookupFailures.isEmpty ? nil : lookupFailures.removeFirst()
            if let gate = lookupGate { lookupGate = nil; await gate.wait() }
            if let injectedFailure { throw injectedFailure }
            if failFirstLookup {
                failFirstLookup = false
                throw V2RoomCallFailure.notAccepted(.unavailable)
            }
            if unreachable { throw V2RoomCallFailure.notAccepted(.unavailable) }
            if recoveryActivation != nil, token == self.token {
                throw V2RoomCallFailure.notAccepted(.staleActivation)
            }
            return !rejectLookups
        }
        var recoveryBatches = 0
        var recoveryActual = 0
        var recoveryPeak = 0
        private var recoveryGates: [V2ActorHostIdentity: Gate] = [:]
        func configureRecoveryGate(_ gate: Gate, host: V2ActorHostIdentity) { recoveryGates[host] = gate }
        func invokeRecoveryBatch(on host: V2ActorHostIdentity, items: [V2RoomRecoveryBatchCallItem],
                                 deadline: ContinuousClock.Instant) async throws -> [V2RoomRecoveryBatchCallOutcome] {
            recoveryBatches += 1
            recoveryActual += 1; recoveryPeak = max(recoveryPeak, recoveryActual)
            defer { recoveryActual -= 1 }
            if let gate = recoveryGates[host] { await gate.wait() }
            #expect(items.allSatisfy { $0.token.host == host && $0.deadline == deadline })
            return items.map { .init(token: $0.token, query: $0.query,
                outcome: .result(.recovery(.state(.unavailable)))) }
        }

        func invoke(_ token: V2RoomActivationToken, request: V2RoomRequest,
                    principal: V2RoomClientPrincipal, deadline: ContinuousClock.Instant) async throws -> V2RoomResponse {
            invoked.append(request)
            invokedTokens.append(token)
            if !failures.isEmpty { throw failures.removeFirst() }
            return .recovery(.failure(.invalidRequest))
        }
        func canInvokeCachedLocally(_ token: V2RoomActivationToken) async -> Bool {
            if let localHintGate { await localHintGate.wait() }
            return localHintAvailable
        }
        func invokeCachedLocally(_ token: V2RoomActivationToken, request: V2RoomRequest,
                                 principal: V2RoomClientPrincipal,
                                 deadline: ContinuousClock.Instant) async throws -> V2RoomResponse {
            localInvocations += 1
            invoked.append(request)
            if !localFailures.isEmpty { throw localFailures.removeFirst() }
            return .recovery(.failure(.invalidRequest))
        }
        func reserve(_ token: V2RoomActivationToken, requestID: UUID,
                     deadline: ContinuousClock.Instant) async throws -> V2RoomReservation {
            .init(token: token, requestID: requestID, reservationID: UUID())
        }
        func markDispatched(_ grant: V2RoomReservation, deadline: ContinuousClock.Instant) async throws {}
        func abort(_ grant: V2RoomReservation, deadline: ContinuousClock.Instant) async -> Bool { true }
        func finish(_ grant: V2RoomReservation, completion: V2RoomReservationCompletion,
                    deadline: ContinuousClock.Instant) async -> Bool { true }
    }

    private actor RecoveryReplies {
        private var batches: [[V2RoomRecoveryQueryOutcome]] = []
        func append(_ values: [V2RoomRecoveryQueryOutcome]) { batches.append(values) }
        func containsRoom(_ room: RoomID) -> Bool { batches.contains { $0.contains { $0.query.roomID == room } } }
        func forRoom(_ room: RoomID) -> [V2RoomRecoveryQueryOutcome] {
            batches.flatMap { $0 }.filter { $0.query.roomID == room }
        }
    }

    private actor Gate {
        private var entries = 0
        private var opened = false
        private var waiting: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            entries += 1
            if opened { return }
            await withCheckedContinuation { waiting.append($0) }
        }
        func open() {
            opened = true
            let pending = waiting
            waiting.removeAll()
            for waiter in pending { waiter.resume() }
        }
        func waitForEntries(_ count: Int) async throws {
            let deadline = ContinuousClock.now + .seconds(2)
            while entries < count {
                guard ContinuousClock.now < deadline else { throw TestFailure.timeout }
                try await Task.sleep(for: .milliseconds(2))
            }
        }
    }
}
