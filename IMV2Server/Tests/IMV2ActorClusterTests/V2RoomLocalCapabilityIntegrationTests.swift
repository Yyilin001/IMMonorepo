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
            #expect(await fixture.client.sessionCount() == 1)
            #expect(await fixture.executions.count() == 1)
        }
    }

    @Test("the caller's smaller request ceiling rejects before local dispatch")
    func callerRequestCeiling() async throws {
        try await withFixture(clientLimits: .init(maximumRequestBytes: 900)) { fixture in
            let token = try await fixture.activate()
            do {
                _ = try await fixture.client.invoke(token, request: fixture.send(
                    text: String(repeating: "x", count: 900)), principal: .user(fixture.user),
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
        try await withFixture(hostLimits: .init(maximumRequestBytes: 700)) { fixture in
            let token = try await fixture.activate()
            do {
                _ = try await fixture.client.invoke(token, request: fixture.send(
                    text: String(repeating: "x", count: 700)), principal: .user(fixture.user),
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
        try await withFixture(hostLimits: .init(maximumReplyBytes: 1_024),
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
                try await fixture.client.invoke(token, request: fixture.send(text: "pending"),
                    principal: .user(fixture.user), deadline: .now + .milliseconds(250))
            }
            try await gate.waitForEntry()
            let first = try await fixture.node.stop(deadline: .now + .milliseconds(40))
            #expect(!first.completed)
            do { _ = try await call.value; Issue.record("timed-out call appeared committed") }
            catch { #expect(error as? V2RoomCallFailure == .outcomeUnknown) }
            #expect(await fixture.client.dispatchedCallCount() == 1)
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
            await gate.open()
            #expect(try await call.value == .recovery(.failure(.invalidRequest)))
            try await fixture.expectReplacementRejected(replacement)
            #expect(await fixture.executions.count() == 1)
        }
    }

    private func withFixture(
        hostLimits: V2ActorAuthenticationLimits = try! .init(),
        clientLimits: V2ActorAuthenticationLimits = try! .init(),
        executionGate: ExecutionGate = .init(),
        largeReply: Bool = false,
        operation: (Fixture) async throws -> Void
    ) async throws {
        let fixture = try await Fixture(hostLimits: hostLimits, clientLimits: clientLimits,
                                        executionGate: executionGate, largeReply: largeReply)
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
        let descriptor: V2RoomClusterHostDescriptor
        let executions: ExecutionGate
        let identity: V2ActorHostIdentity
        let room = RoomID(uuid: UUID())
        let user = UserID(uuid: UUID())
        let owner: V2RoomDataOwner
        let temporaryDirectory: URL

        init(hostLimits: V2ActorAuthenticationLimits = try! .init(),
             clientLimits: V2ActorAuthenticationLimits = try! .init(),
             executionGate: ExecutionGate = .init(), largeReply: Bool = false) async throws {
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
                maximumConcurrentReservations: 1)
            let oversizedResponse: V2RoomResponse = .roomLog(.page(try .init(
                roomID: .init(uuid: UUID()),
                events: [try .init(sourceEventID: .init(uuid: UUID()), roomSequence: 1,
                                   projectionKind: "test", payload: Data(repeating: 7, count: 4_096))],
                nextRoomSequence: 1, hasMore: false, logTrimmedThroughRoomSequence: 0)))
            let host = V2RoomActivationHost<V2RoomRequest, V2RoomResponse>(identity: hostIdentity,
                leaseStore: LocalLeaseStore(), configuration: runtime,
                budget: V2RoomCommandBudget(configuration: runtime), classify: { _ in .barrier },
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

        func activate() async throws -> V2RoomActivationToken {
            let result = try await client.activate(on: identity, roomID: room,
                owner: owner, deadline: .now + .seconds(5))
            guard case .ready(let token) = result else { throw V2ActorAuthenticationError.wrongRecipient }
            return token
        }

        func send(text: String) -> V2RoomRequest {
            .messaging(.send(.init(roomID: room, actorUserID: user,
                clientMessageID: .init(uuid: UUID()), text: text, media: [], mentions: [],
                entities: [], replyTo: nil)))
        }

        func removeTemporaryFiles() throws {
            try FileManager.default.removeItem(at: temporaryDirectory)
        }

        func expectReplacementRejected(_ replacement: V2ActorHostIdentity) async throws {
            var rejected = false
            do {
                _ = try await client.activate(on: replacement, roomID: .init(uuid: UUID()),
                    owner: owner, deadline: .now + .milliseconds(500))
            } catch {
                rejected = true
            }
            #expect(rejected, "old local capability accepted a replacement host incarnation")
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
        private var lease: V2RoomActivationLease?

        func locate(roomID: RoomID, owner: V2RoomDataOwner) async throws -> V2RoomActivationLease? {
            guard let lease, lease.token.roomID == roomID, lease.token.owner == owner else { return nil }
            return lease
        }

        func acquire(roomID: RoomID, owner: V2RoomDataOwner, host: V2ActorHostIdentity,
                     duration: V2ActorMilliseconds) async throws -> V2RoomActivationAcquisition {
            if let lease { return .occupied(lease) }
            let token = V2RoomActivationToken(roomID: roomID, owner: owner,
                activationEpoch: try .init(1), host: host)
            let value = try makeLease(token, duration: duration)
            lease = value
            return .acquired(value)
        }

        func renew(token: V2RoomActivationToken,
                   duration: V2ActorMilliseconds) async throws -> V2RoomActivationLease {
            guard lease?.token == token else { throw V2RoomActivationLeaseError.activationChanged }
            let value = try makeLease(token, duration: duration)
            lease = value
            return value
        }

        func release(token: V2RoomActivationToken) async throws -> Bool {
            guard lease?.token == token else { return false }
            lease = nil
            return true
        }

        private func makeLease(_ token: V2RoomActivationToken,
                               duration: V2ActorMilliseconds) throws -> V2RoomActivationLease {
            let observed = Date(timeIntervalSince1970: 1_000)
            return try .init(token: token, databaseObservedAt: observed,
                expiresAt: observed.addingTimeInterval(Double(duration.rawValue) / 1_000))
        }
    }
}
