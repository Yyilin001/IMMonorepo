import Crypto
import Foundation
import IMV2ActorContracts
import IMV2ActorRuntime
import IMV2Core
import NIOSSL
import Testing
@testable import IMV2ActorCluster

@Suite("Node-minted local room capability", .serialized, .timeLimit(.minutes(2)))
struct V2RoomLocalCapabilityIntegrationTests {
    @Test("node client activates and invokes through a bounded local session")
    func localTurn() async throws {
        try await withFixture { fixture in
            let token = try await fixture.activate()
            let response = try await fixture.client.invoke(token, request: fixture.send(text: "local"),
                principal: .user(fixture.user), deadline: .now + .seconds(5))
            #expect(response == .recovery(.failure(.invalidRequest)))
            #expect(await fixture.client.canInvokeCachedLocally(token))
            let hinted = try await fixture.client.invokeCachedLocally(token,
                request: fixture.send(text: "hinted"), principal: .user(fixture.user),
                deadline: .now + .seconds(5))
            #expect(hinted == .recovery(.failure(.invalidRequest)))
            #expect(await fixture.client.sessionCount() == 1)
            #expect(await fixture.executions.count() == 2)
        }
    }

    @Test("cached stable operations dispatch once each without placement lookup")
    func cachedMessageCalls() async throws {
        try await withFixture { fixture in
            let token = try await fixture.activate()
            let before = await fixture.client.callMetricsSnapshot()
            for _ in 0..<4 {
                let result = try await fixture.client.tryInvokeCached(token,
                    request: fixture.send(text: "cached"), principal: .user(fixture.user),
                    deadline: .now + .seconds(5))
                guard case .response(let response) = result else { Issue.record("expected cache hit"); return }
                #expect(response == .recovery(.failure(.invalidRequest)))
            }
            let after = await fixture.client.callMetricsSnapshot()
            #expect(after.roomLookups == before.roomLookups)
            #expect(after.roomInvocations - before.roomInvocations == 4)
            #expect(after.cachedLocalCalls - before.cachedLocalCalls == 4)
            #expect(after.hostRecoveryProbes == 0)
            #expect(await fixture.executions.count() == 4)
        }
    }

    @Test("a cached reference miss does not dispatch or perform hidden lookup")
    func cachedMessageMiss() async throws {
        try await withFixture(maximumCachedLocations: 1) { fixture in
            let token = try await fixture.activate()
            _ = try await fixture.activate(roomID: .init(uuid: UUID()))
            let before = await fixture.client.callMetricsSnapshot()
            let result = try await fixture.client.tryInvokeCached(token,
                request: fixture.send(text: "evicted-cache"), principal: .user(fixture.user),
                deadline: .now + .seconds(5))
            guard case .cacheMiss = result else { Issue.record("expected cache miss"); return }
            let after = await fixture.client.callMetricsSnapshot()
            #expect(after.roomLookups == before.roomLookups)
            #expect(after.roomInvocations == before.roomInvocations)
            #expect(after.referenceMisses == before.referenceMisses + 1)
            #expect(await fixture.executions.count() == 0)
        }
    }

    @Test("an executing cached call returns its actual result after eviction and same-token reinstall")
    func cachedCallEvictionAndReinstall() async throws {
        let gate = ExecutionGate(closed: true)
        try await withFixture(executionGate: gate, maximumCachedLocations: 1) { fixture in
            let token = try await fixture.activate()
            let call = Task {
                try await fixture.client.tryInvokeCached(token, request: fixture.send(text: "held-cache"),
                    principal: .user(fixture.user), deadline: .now + .seconds(5))
            }
            try await gate.waitForEntry()
            _ = try await fixture.activate(roomID: .init(uuid: UUID()))
            #expect(try await fixture.client.lookup(token, deadline: .now + .seconds(5)))
            await gate.open()
            guard case .response(let response) = try await call.value else {
                Issue.record("dispatched cached call became a cache miss"); return
            }
            #expect(response == .recovery(.failure(.invalidRequest)))
            #expect(await fixture.client.canInvokeCachedLocally(token))
            #expect(await fixture.executions.count() == 1)
            #expect(await fixture.client.dispatchedCallCount() == 0)
        }
    }

    // Local limits account for retained models, including the activation envelope.
    // Leave room for setup, then exceed the limit with the business payload.
    @Test("the caller's smaller request ceiling rejects before local dispatch")
    func callerRequestCeiling() async throws {
        try await withFixture(clientLimits: .init(maximumRequestBytes: 16_384)) { fixture in
            let token = try await fixture.activate()
            do {
                _ = try await fixture.client.invoke(token, request: fixture.send(
                    text: String(repeating: "x", count: 16_384)), principal: .user(fixture.user),
                    deadline: .now + .seconds(5))
                Issue.record("oversized local request dispatched")
            } catch {
                #expect(error as? V2RoomCallFailure == .notAccepted(.invalidRequest))
            }
            #expect(await fixture.executions.count() == 0)
        }
    }

    @Test("the host's smaller request ceiling rejects under its own trust boundary")
    func hostRequestCeiling() async throws {
        try await withFixture(hostLimits: .init(maximumRequestBytes: 16_384)) { fixture in
            let token = try await fixture.activate()
            do {
                _ = try await fixture.client.invoke(token, request: fixture.send(
                    text: String(repeating: "x", count: 16_384)), principal: .user(fixture.user),
                    deadline: .now + .seconds(5))
                Issue.record("host-oversized local request dispatched")
            } catch {
                #expect(error as? V2RoomCallFailure == .outcomeUnknown)
            }
            #expect(await fixture.executions.count() == 0)
        }
    }

    @Test("the host's smaller reply ceiling is enforced after local execution")
    func hostReplyCeiling() async throws {
        try await withFixture(hostLimits: .init(maximumReplyBytes: 16_384),
                              largeReply: true) { fixture in
            let token = try await fixture.activate()
            do {
                _ = try await fixture.client.invoke(token, request: fixture.send(text: "reply"),
                    principal: .user(fixture.user), deadline: .now + .seconds(5))
                Issue.record("oversized host reply was accepted")
            } catch {
                #expect(error as? V2RoomCallFailure == .outcomeUnknown)
            }
            #expect(await fixture.executions.count() == 1)
        }
    }

    @Test("timed-out local SQL-like work remains tracked until drain can finish")
    func localTimeoutAndDrain() async throws {
        let gate = ExecutionGate(closed: true)
        try await withFixture(executionGate: gate) { fixture in
            let token = try await fixture.activate()
            let call = Task {
                try await fixture.client.invokeCachedLocally(token, request: fixture.send(text: "pending"),
                    principal: .user(fixture.user), deadline: .now + .milliseconds(250))
            }
            try await gate.waitForEntry()
            let first = try await fixture.node.stop(deadline: .now + .milliseconds(40))
            #expect(!first.completed)
            #expect(first.remainingRooms == 1)
            do { _ = try await call.value; Issue.record("timed-out call appeared committed") }
            catch { #expect(error as? V2RoomCallFailure == .outcomeUnknown) }
            // The Host detaches the timed-out caller but owns the executing
            // turn, permit and lease until the executor actually finishes.
            // Once the inbound unknown reply has returned, the Client's
            // physical dispatch is correctly allowed to leave its registry.
            #expect(await fixture.client.quiesce(deadline: .now + .seconds(2)))
            #expect(await fixture.client.dispatchedCallCount() == 0)
            #expect(await gate.hasPendingExecution())
            let heldBudget = await fixture.budget.snapshot()
            #expect(heldBudget.commandCount == 1)
            #expect(heldBudget.byteCount > 0)
            let heldLease = try await fixture.leases.locate(roomID: fixture.room, owner: fixture.owner)
            #expect(heldLease?.token == token)
            let stillDraining = try await fixture.node.stop(deadline: .now + .milliseconds(40))
            #expect(!stillDraining.completed)
            #expect(stillDraining.remainingRooms == 1)

            await gate.open()
            let finished = try await fixture.node.stop(deadline: .now + .seconds(5))
            #expect(finished.completed)
            #expect(finished.remainingRooms == 0)
            #expect(await fixture.executions.count() == 1)
            let releasedBudget = await fixture.budget.snapshot()
            #expect(releasedBudget.commandCount == 0)
            #expect(releasedBudget.byteCount == 0)
            let releasedLease = try await fixture.leases.locate(roomID: fixture.room, owner: fixture.owner)
            #expect(releasedLease?.token == nil)
            #expect(await fixture.client.dispatchedCallCount() == 0)
        }
    }

    @Test("expired local session removes the hint until authenticated lookup renews it")
    func expiredSession() async throws {
        try await withFixture(hostLimits: .init(sessionLifetimeMilliseconds: 1_200)) { fixture in
            let token = try await fixture.activate()
            #expect(await fixture.client.canInvokeCachedLocally(token))
            try await Task.sleep(for: .milliseconds(1_250))
            #expect(!(await fixture.client.canInvokeCachedLocally(token)))
            #expect(try await fixture.client.lookup(token, deadline: .now + .seconds(5)))
            #expect(await fixture.client.canInvokeCachedLocally(token))
        }
    }

    @Test("suspension closes new admission before the old physical call drains")
    func suspendBeforeActualDrain() async throws {
        let gate = ExecutionGate(closed: true)
        try await withFixture(executionGate: gate) { fixture in
            let token = try await fixture.activate()
            let call = Task {
                try await fixture.client.invoke(token, request: fixture.send(text: "before-suspend"),
                    principal: .user(fixture.user), deadline: .now + .seconds(5))
            }
            try await gate.waitForEntry()
            #expect(!(await fixture.client.suspendUnreachableHost(fixture.identity)))
            do {
                _ = try await fixture.client.invoke(token, request: fixture.send(text: "closed-admission"),
                    principal: .user(fixture.user), deadline: .now + .seconds(2))
                Issue.record("new business RPC crossed suspended host admission")
            } catch { #expect(error as? V2RoomCallFailure == .notAccepted(.unavailable)) }
            #expect(await fixture.executions.count() == 1)
            await gate.open()
            #expect(try await call.value == .recovery(.failure(.invalidRequest)))
            #expect(await fixture.client.suspendUnreachableHost(fixture.identity))
            #expect(await fixture.client.dispatchedCallCount() == 0)
        }
    }

    @Test("a replaced local descriptor retains its in-flight result but cannot reuse its capability")
    func localDescriptorReplacement() async throws {
        let gate = ExecutionGate(closed: true)
        try await withFixture(executionGate: gate) { fixture in
            let token = try await fixture.activate()
            let call = Task {
                try await fixture.client.invoke(token, request: fixture.send(text: "old-generation"),
                    principal: .user(fixture.user), deadline: .now + .seconds(5))
            }
            try await gate.waitForEntry()
            let replacement = V2ActorHostIdentity(hostID: fixture.identity.hostID,
                                                  incarnationID: UUID())
            let oldDescriptor = fixture.descriptor
            try await fixture.client.installDiscovered(.init(identity: replacement,
                endpointID: oldDescriptor.endpointID, address: oldDescriptor.address,
                port: oldDescriptor.port, accessibleShardIDs: oldDescriptor.accessibleShardIDs,
                availableRooms: oldDescriptor.availableRooms, isHealthy: true))
            #expect(await fixture.client.retiredDescriptorCount() == 1)
            #expect(!(await fixture.client.canInvokeCachedLocally(token)))
            do {
                _ = try await fixture.client.invokeCachedLocally(token,
                    request: fixture.send(text: "must-not-route-remote"),
                    principal: .user(fixture.user), deadline: .now + .seconds(2))
                Issue.record("replaced descriptor accepted an old local hint")
            } catch {
                guard case .notAccepted = error as? V2RoomCallFailure else {
                    Issue.record("expected a definite pre-dispatch rejection: \(error)")
                    return
                }
            }
            await gate.open()
            #expect(try await call.value == .recovery(.failure(.invalidRequest)))
            try await fixture.expectReplacementRejected(replacement)
            #expect(await fixture.executions.count() == 1)
        }
    }

    @Test("physical reference eviction fails the local hint and requires a lookup")
    func evictedReference() async throws {
        try await withFixture(maximumCachedLocations: 1) { fixture in
            let first = try await fixture.activate()
            #expect(await fixture.client.canInvokeCachedLocally(first))
            let otherRoom = RoomID(uuid: UUID())
            let second = try await fixture.activate(roomID: otherRoom)
            #expect(await fixture.client.canInvokeCachedLocally(second))
            #expect(!(await fixture.client.canInvokeCachedLocally(first)))
            do {
                _ = try await fixture.client.invokeCachedLocally(first,
                    request: fixture.send(text: "evicted"), principal: .user(fixture.user),
                    deadline: .now + .seconds(2))
                Issue.record("evicted physical reference accepted a local hint")
            } catch {
                guard case .notAccepted = error as? V2RoomCallFailure else {
                    Issue.record("expected definite eviction rejection: \(error)")
                    return
                }
            }
            #expect(await fixture.executions.count() == 0)
            #expect(try await fixture.client.lookup(first, deadline: .now + .seconds(5)))
            #expect(await fixture.client.canInvokeCachedLocally(first))
            #expect(!(await fixture.client.canInvokeCachedLocally(second)))
        }
    }

    @Test("a descriptor replacement between local resolution and dispatch cannot route remotely")
    func localHintDescriptorRace() async throws {
        try await withFixture { fixture in
            let token = try await fixture.activate()
            let gate = ExecutionGate(closed: true)
            let transport = PausedHintTransport(client: fixture.client, gate: gate)
            let owners = StaticOwner(owner: fixture.owner)
            let directory = V2RoomDirectory(owners: owners, leases: StaticLease(token: token),
                hosts: fixture.client, transport: transport,
                configuration: try .init(maximumActiveRooms: 2, maximumConcurrentRestores: 1,
                    maximumActivationWaitersPerRoom: 2, maximumPendingActivations: 2,
                    maximumActivationWaitersPerHost: 4, maximumConcurrentResolutions: 1,
                    maximumConcurrentReservations: 1))
            #expect(try await directory.resolve(fixture.room, deadline: .now + .seconds(5)) == token)
            #expect(await fixture.client.canInvokeCachedLocally(token))
            let call = Task {
                try await directory.room(fixture.room).call(fixture.send(text: "held-hint"),
                    principal: .user(fixture.user), deadline: .now + .seconds(5))
            }
            do {
                try await gate.waitForEntry() // the real client answered true; the hint has not returned
                let prior = fixture.descriptor
                try await fixture.client.installDiscovered(.init(identity: .init(
                    hostID: fixture.identity.hostID, incarnationID: UUID()),
                    endpointID: prior.endpointID, address: prior.address, port: prior.port,
                    accessibleShardIDs: prior.accessibleShardIDs,
                    availableRooms: prior.availableRooms, isHealthy: true))
            } catch {
                await gate.open()
                call.cancel()
                _ = try? await call.value
                _ = await directory.quiesce(deadline: .now + .seconds(2))
                throw error
            }
            await gate.open()
            do { _ = try await call.value; Issue.record("stale local hint executed") }
            catch { #expect(error is V2RoomCallFailure) }
            #expect(await transport.localInvocations == 1)
            let localFailure = await transport.localFailure
            // The replaced descriptor may already be absent at the first
            // exchange guard; either failure proves it was never dispatched.
            #expect(localFailure == .notAccepted(.staleActivation) ||
                    localFailure == .notAccepted(.unavailable))
            #expect(await owners.calls >= 2) // existing retryAction attempted authoritative relocation
            #expect(await fixture.executions.count() == 0)
            #expect(await directory.quiesce(deadline: .now + .seconds(2)))
        }
    }

    private func withFixture(
        hostLimits: V2ActorAuthenticationLimits = try! .init(),
        clientLimits: V2ActorAuthenticationLimits = try! .init(),
        executionGate: ExecutionGate = .init(),
        largeReply: Bool = false,
        maximumCachedLocations: Int = 1_024,
        operation: (Fixture) async throws -> Void
    ) async throws {
        let fixture = try await Fixture(hostLimits: hostLimits, clientLimits: clientLimits,
                                        executionGate: executionGate, largeReply: largeReply,
                                        maximumCachedLocations: maximumCachedLocations)
        var operationError: (any Error)?
        do { try await operation(fixture) }
        catch { operationError = error }
        await executionGate.open()
        do {
            let stopped = try await fixture.node.stop(deadline: .now + .seconds(5))
            if !stopped.completed { throw V2ActorAuthenticationError.overloaded }
        } catch {
            Issue.record("local test node did not fully stop: \(error)")
            if operationError == nil { operationError = error }
        }
        do { try fixture.removeTemporaryFiles() }
        catch {
            Issue.record("local test certificate cleanup failed: \(error)")
            if operationError == nil { operationError = error }
        }
        if let operationError { throw operationError }
    }

    private struct Fixture: Sendable {
        let node: V2RoomClusterNode
        let client: V2RoomClusterClient
        let budget: V2RoomCommandBudget
        let leases: LocalLeaseStore
        let descriptor: V2RoomClusterHostDescriptor
        let executions: ExecutionGate
        let identity: V2ActorHostIdentity
        let room = RoomID(uuid: UUID())
        let user = UserID(uuid: UUID())
        let owner: V2RoomDataOwner
        let temporaryDirectory: URL

        init(hostLimits: V2ActorAuthenticationLimits = try! .init(),
             clientLimits: V2ActorAuthenticationLimits = try! .init(),
             executionGate: ExecutionGate = .init(), largeReply: Bool = false,
             maximumCachedLocations: Int = 1_024) async throws {
            self.executions = executionGate
            let directory = FileManager.default.temporaryDirectory
                .appending(path: "imv2-local-capability-\(UUID())")
            temporaryDirectory = directory
            try FileManager.default.createDirectory(at: directory,
                withIntermediateDirectories: true)
            var initialized = false
            defer { if !initialized { try? FileManager.default.removeItem(at: directory) } }
            let cert = directory.appending(path: "cert.pem")
            let key = directory.appending(path: "key.pem")
            let openssl = Process()
            openssl.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            openssl.arguments = ["openssl", "req", "-x509", "-newkey", "ec",
                "-pkeyopt", "ec_paramgen_curve:P-256", "-nodes", "-days", "1",
                "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost",
                "-keyout", key.path, "-out", cert.path]
            openssl.standardOutput = FileHandle.nullDevice
            openssl.standardError = FileHandle.nullDevice
            try openssl.run()
            openssl.waitUntilExit()
            try #require(openssl.terminationStatus == 0)
            let certificates = try NIOSSLCertificate.fromPEMFile(cert.path)
            var tls = TLSConfiguration.makeServerConfiguration(
                certificateChain: certificates.map { .certificate($0) },
                privateKey: .privateKey(try NIOSSLPrivateKey(file: key.path, format: .pem)))
            tls.minimumTLSVersion = .tlsv13
            tls.maximumTLSVersion = .tlsv13
            tls.certificateVerification = .fullVerification
            tls.trustRoots = .certificates(certificates)

            let hostIdentity = V2ActorHostIdentity(hostID: .init(uuid: UUID()), incarnationID: UUID())
            identity = hostIdentity
            owner = try .init(shardID: "allowed", epoch: 0)
            let callerKey = Curve25519.Signing.PrivateKey()
            let hostKey = Curve25519.Signing.PrivateKey()
            let caller = try V2ActorSigningIdentity(serviceID: .init("gateway"),
                privateKey: callerKey.rawRepresentation)
            let signer = try V2ActorSigningIdentity(serviceID: .init("host"),
                privateKey: hostKey.rawRepresentation)
            let trust = try V2ActorTrustStore(services: [
                .init(serviceID: caller.serviceID, publicKey: callerKey.publicKey.rawRepresentation,
                      permissions: [.userRoomCalls]),
                .init(serviceID: signer.serviceID, publicKey: hostKey.publicKey.rawRepresentation,
                      permissions: [], hostedIDs: [hostIdentity.hostID]),
            ])
            let runtime = try V2RoomRuntimeConfiguration(
                maximumActiveRooms: 2, maximumConcurrentRestores: 1,
                maximumActivationWaitersPerRoom: 2, maximumPendingActivations: 2,
                maximumActivationWaitersPerHost: 4, maximumConcurrentResolutions: 1,
                maximumCachedLocations: maximumCachedLocations,
                maximumConcurrentReservations: 1)
            let oversizedResponse: V2RoomResponse = .roomLog(.page(try .init(
                roomID: .init(uuid: UUID()),
                events: [try .init(sourceEventID: .init(uuid: UUID()), roomSequence: 1,
                                   projectionKind: "test", payload: Data(repeating: 7, count: 32_768))],
                nextRoomSequence: 1, hasMore: false, logTrimmedThroughRoomSequence: 0)))
            let leaseStore = LocalLeaseStore()
            leases = leaseStore
            let commandBudget = V2RoomCommandBudget(configuration: runtime)
            budget = commandBudget
            let host = V2RoomActivationHost<V2RoomRequest, V2RoomResponse>(identity: hostIdentity,
                leaseStore: leaseStore, configuration: runtime,
                budget: commandBudget, classify: { _ in .barrier },
                factory: .init { _ in
                    .init(restore: { _ in }, execute: { turn in
                        await executionGate.waitIfClosed()
                        return .committed(turn.items.map { _ in
                            largeReply ? oversizedResponse : .recovery(.failure(.invalidRequest))
                        })
                    }, invalidateReservation: { _ in }, close: {})
                })
            let config = try V2RoomClusterNodeConfiguration(name: "v2-local-capability-test",
                host: "localhost", port: Int.random(in: 30_000...60_000), tls: tls,
                threadPoolSize: 1, allowedShards: ["allowed"],
                serviceShardAccess: [caller.serviceID: ["allowed"]])
            let hostedNode = V2RoomClusterNode(configuration: config, identity: hostIdentity, host: host,
                signer: signer, trust: trust, authenticationLimits: hostLimits,
                runtimeConfiguration: runtime)
            node = hostedNode
            do {
                let descriptor = try await hostedNode.start()
                self.descriptor = descriptor
                let hostedClient = try await hostedNode.makeClient(signer: caller, trust: trust,
                                                                   limits: clientLimits)
                client = hostedClient
                try await hostedClient.installDiscovered(descriptor)
                initialized = true
            } catch {
                _ = try? await hostedNode.stop(deadline: .now + .seconds(5))
                throw error
            }
        }

        func activate(roomID: RoomID? = nil) async throws -> V2RoomActivationToken {
            let result = try await client.activate(on: identity, roomID: roomID ?? room,
                owner: owner, deadline: .now + .seconds(5))
            guard case .ready(let token) = result else { throw V2ActorAuthenticationError.wrongRecipient }
            return token
        }

        func send(text: String) throws -> V2RoomRequest {
            .messaging(.sendOperation(try .init(command: try .init(roomID: room, senderUserID: user,
                clientMessageID: .init(uuid: UUID()), text: text, media: [], mentions: [],
                entities: [], replyTo: nil, limits: .init(maxUTF8Bytes: 65_536)), firstSubmissionDeadlineMilliseconds: 1_900_000_000_000)))
        }

        func removeTemporaryFiles() throws {
            try FileManager.default.removeItem(at: temporaryDirectory)
        }

        func expectReplacementRejected(_ replacement: V2ActorHostIdentity) async throws {
            do {
                _ = try await client.activate(on: replacement, roomID: .init(uuid: UUID()),
                    owner: owner, deadline: .now + .milliseconds(500))
                Issue.record("old local capability accepted a replacement host incarnation")
            } catch {
                #expect(error as? V2ActorAuthenticationError == .wrongRecipient)
            }
        }
    }

    private actor ExecutionGate {
        private var entered = 0
        private var closed = false
        private var pending: CheckedContinuation<Void, Never>?

        init(closed: Bool = false) { self.closed = closed }

        func waitIfClosed() async {
            entered += 1
            if closed { await withCheckedContinuation { pending = $0 } }
        }

        func count() -> Int { entered }

        func hasPendingExecution() -> Bool { pending != nil }

        func waitForEntry() async throws {
            let deadline = ContinuousClock.now + .seconds(3)
            while entered == 0 {
                guard ContinuousClock.now < deadline else { throw V2ActorAuthenticationError.overloaded }
                try await Task.sleep(for: .milliseconds(2))
            }
        }

        func open() { closed = false; pending?.resume(); pending = nil }
    }

    private actor LocalLeaseStore: V2RoomActivationLeaseStore {
        private var leases: [RoomID: V2RoomActivationLease] = [:]

        func locate(roomID: RoomID, owner: V2RoomDataOwner) async throws -> V2RoomActivationLease? {
            guard let lease = leases[roomID], lease.token.owner == owner else { return nil }
            return lease
        }

        func acquire(roomID: RoomID, owner: V2RoomDataOwner, host: V2ActorHostIdentity,
                     duration: V2ActorMilliseconds) async throws -> V2RoomActivationAcquisition {
            if let lease = leases[roomID] { return .occupied(lease) }
            let token = V2RoomActivationToken(roomID: roomID, owner: owner,
                activationEpoch: try .init(1), host: host)
            let value = try makeLease(token, duration: duration)
            leases[roomID] = value
            return .acquired(value)
        }

        func renew(token: V2RoomActivationToken,
                   duration: V2ActorMilliseconds) async throws -> V2RoomActivationLease {
            guard leases[token.roomID]?.token == token else { throw V2RoomActivationLeaseError.activationChanged }
            let value = try makeLease(token, duration: duration)
            leases[token.roomID] = value
            return value
        }

        func release(token: V2RoomActivationToken) async throws -> Bool {
            guard leases[token.roomID]?.token == token else { return false }
            leases.removeValue(forKey: token.roomID)
            return true
        }

        private func makeLease(_ token: V2RoomActivationToken,
                               duration: V2ActorMilliseconds) throws -> V2RoomActivationLease {
            let observed = Date(timeIntervalSince1970: 1_000)
            return try .init(token: token, databaseObservedAt: observed,
                expiresAt: observed.addingTimeInterval(Double(duration.rawValue) / 1_000))
        }
    }

    private actor StaticOwner: V2RoomDataOwnerResolving {
        let owner: V2RoomDataOwner
        var calls = 0
        init(owner: V2RoomDataOwner) { self.owner = owner }
        func owner(for roomID: RoomID) async throws -> V2RoomDataOwner {
            calls += 1
            return owner
        }
    }

    private actor StaticLease: V2RoomActivationLeaseStore {
        let token: V2RoomActivationToken
        init(token: V2RoomActivationToken) { self.token = token }
        func locate(roomID: RoomID, owner: V2RoomDataOwner) async throws -> V2RoomActivationLease? {
            guard roomID == token.roomID, owner == token.owner else { return nil }
            return try .init(token: token, databaseObservedAt: Date(timeIntervalSince1970: 1_000),
                expiresAt: Date(timeIntervalSince1970: 1_030))
        }
        func acquire(roomID: RoomID, owner: V2RoomDataOwner, host: V2ActorHostIdentity,
                     duration: V2ActorMilliseconds) async throws -> V2RoomActivationAcquisition {
            throw V2RoomActivationLeaseError.activationChanged
        }
        func renew(token: V2RoomActivationToken,
                   duration: V2ActorMilliseconds) async throws -> V2RoomActivationLease {
            throw V2RoomActivationLeaseError.activationChanged
        }
        func release(token: V2RoomActivationToken) async throws -> Bool { false }
    }

    private actor PausedHintTransport: V2RoomClientTransport {
        let client: V2RoomClusterClient
        let gate: ExecutionGate
        var localInvocations = 0
        var localFailure: V2RoomCallFailure?
        init(client: V2RoomClusterClient, gate: ExecutionGate) {
            self.client = client
            self.gate = gate
        }
        func canInvokeCachedLocally(_ token: V2RoomActivationToken) async -> Bool {
            let available = await client.canInvokeCachedLocally(token)
            if available { await gate.waitIfClosed() }
            return available
        }
        func activate(on host: V2ActorHostIdentity, roomID: RoomID, owner: V2RoomDataOwner,
                      deadline: ContinuousClock.Instant) async throws -> V2RoomActivationResolution {
            try await client.activate(on: host, roomID: roomID, owner: owner, deadline: deadline)
        }
        func lookup(_ token: V2RoomActivationToken,
                    deadline: ContinuousClock.Instant) async throws -> Bool {
            try await client.lookup(token, deadline: deadline)
        }
        func invoke(_ token: V2RoomActivationToken, request: V2RoomRequest,
                    principal: V2RoomClientPrincipal,
                    deadline: ContinuousClock.Instant) async throws -> V2RoomResponse {
            try await client.invoke(token, request: request, principal: principal, deadline: deadline)
        }
        func invokeCachedLocally(_ token: V2RoomActivationToken, request: V2RoomRequest,
                                 principal: V2RoomClientPrincipal,
                                 deadline: ContinuousClock.Instant) async throws -> V2RoomResponse {
            localInvocations += 1
            do {
                return try await client.invokeCachedLocally(token, request: request,
                    principal: principal, deadline: deadline)
            } catch {
                localFailure = error as? V2RoomCallFailure
                throw error
            }
        }
        func reserve(_ token: V2RoomActivationToken, requestID: UUID,
                     deadline: ContinuousClock.Instant) async throws -> V2RoomReservation {
            try await client.reserve(token, requestID: requestID, deadline: deadline)
        }
        func markDispatched(_ grant: V2RoomReservation,
                            deadline: ContinuousClock.Instant) async throws {
            try await client.markDispatched(grant, deadline: deadline)
        }
        func abort(_ grant: V2RoomReservation, deadline: ContinuousClock.Instant) async -> Bool {
            await client.abort(grant, deadline: deadline)
        }
        func finish(_ grant: V2RoomReservation, completion: V2RoomReservationCompletion,
                    deadline: ContinuousClock.Instant) async -> Bool {
            await client.finish(grant, completion: completion, deadline: deadline)
        }
    }
}
