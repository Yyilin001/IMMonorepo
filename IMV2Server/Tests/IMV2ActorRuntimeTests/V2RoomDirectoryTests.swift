import Foundation
import IMV2ActorContracts
import IMV2Core
import Testing
@testable import IMV2ActorRuntime

@Suite("Logical room references resolve through the owner and lease")
struct V2RoomDirectoryTests {
    @Test("concurrent callers share one bounded resolution")
    func singleflight() async throws {
        let gate = Gate()
        let fixture = try Fixture(ownerGate: gate)
        let first = Task { try await fixture.directory.resolve(fixture.room, deadline: .now + .seconds(2)) }
        try await gate.waitForEntries(1)
        let second = Task { try await fixture.directory.resolve(fixture.room, deadline: .now + .seconds(2)) }
        try await waitUntil { await fixture.directory.snapshot().waiters == 2 }
        await gate.open()
        #expect(try await first.value == fixture.token)
        #expect(try await second.value == fixture.token)
        #expect(await fixture.owners.calls == 1)
        #expect(await fixture.leases.locates == 1)
        #expect(await fixture.transport.activations == 1)
    }

    @Test("drain rejects waiters while quiesce retains the actual owner lookup")
    func drainTracksResolution() async throws {
        let gate = Gate()
        let fixture = try Fixture(ownerGate: gate)
        let call = Task { try await fixture.directory.resolve(fixture.room, deadline: .now + .seconds(2)) }
        try await gate.waitForEntries(1)
        #expect(await fixture.directory.quiesce(deadline: .now + .milliseconds(20)) == false)
        await failure(.notAccepted(.retired)) { _ = try await call.value }
        #expect(await fixture.directory.snapshot().active == 1)
        await gate.open()
        #expect(await fixture.directory.quiesce(deadline: .now + .seconds(1)))
        #expect(await fixture.directory.snapshot().active == 0)
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
        #expect(await fixture.leases.locates >= 2)
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
        #expect(await fixture.owners.calls == 2)
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
        #expect(await fixture.transport.localInvocations == 1)
        #expect(await fixture.transport.invoked == [command, command])
        #expect(await fixture.transport.lookups.count == 1)
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
             callTimeoutMilliseconds: Int64 = 30_000) throws {
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
                                  localFailures: localFailures)
            let provider = Hosts(host: host)
            let configuration = try V2RoomRuntimeConfiguration(
                maximumActiveRooms: 2, maximumConcurrentRestores: 1,
                maximumActivationWaitersPerRoom: 3, maximumPendingActivations: 2,
                maximumActivationWaitersPerHost: 3, maximumConcurrentResolutions: 2,
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
        init(owner: V2RoomDataOwner, gate: Gate?, missing: Bool) {
            self.owner = owner; self.gate = gate; self.missing = missing
        }
        func owner(for roomID: RoomID) async throws -> V2RoomDataOwner {
            calls += 1
            if let gate { await gate.wait() }
            if missing { throw V2RoomActivationLeaseError.roomNotFound }
            return owner
        }
    }

    private actor Leases: V2RoomActivationLeaseStore {
        var lease: V2RoomActivationLease?
        var locates = 0
        init(lease: V2RoomActivationLease?) { self.lease = lease }
        func setLease(_ value: V2RoomActivationLease) { lease = value }
        func locate(roomID: RoomID, owner: V2RoomDataOwner) async throws -> V2RoomActivationLease? {
            locates += 1
            return lease
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
        init(token: V2RoomActivationToken, unreachable: Bool,
             activationFailure: V2RoomCallFailure?, failures: [V2RoomCallFailure],
             failFirstLookup: Bool, localHintAvailable: Bool, localHintGate: Gate?,
             localFailures: [V2RoomCallFailure]) {
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
            return .ready(token)
        }
        func lookup(_ token: V2RoomActivationToken, deadline: ContinuousClock.Instant) async throws -> Bool {
            lookups.append((token, ContinuousClock.now.duration(to: deadline)))
            if failFirstLookup {
                failFirstLookup = false
                throw V2RoomCallFailure.notAccepted(.unavailable)
            }
            if unreachable { throw V2RoomCallFailure.notAccepted(.unavailable) }
            return true
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
