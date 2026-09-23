import Crypto
import Foundation
import IMV2ActorContracts
import IMV2Core
import Synchronization
import Testing
@testable import IMV2ActorCluster

@Suite("Signed actor sessions bind authority and reject replay")
struct V2ActorAuthenticationTests {
    @Test("user identity and complete typed payload are covered by the signature")
    func signatureAndPrincipal() async throws {
        let fixture = try Fixture()
        let grant = try await fixture.open()
        let call = try fixture.call(grant: grant)
        let packet = try fixture.client.sign(call, maximumBytes: fixture.limits.maximumRequestBytes)
        let verified = try await fixture.auth.accept(packet)
        #expect(verified.call == call)
        var tampered = packet.body
        tampered[tampered.startIndex] ^= 1
        await failure(.invalidSignature) {
            _ = try await fixture.auth.accept(.init(signerID: packet.signerID, body: tampered, signature: packet.signature))
        }
        let wrongUser = try fixture.call(grant: grant, sequence: 2, principal: .user(UserID(uuid: UUID())))
        await failure(.forbidden) {
            _ = try await fixture.auth.accept(fixture.client.sign(wrongUser, maximumBytes: 10_000))
        }
    }

    @Test("out of order delivery is bounded and duplicate sequence or attempt never dispatches twice")
    func replayWindow() async throws {
        let fixture = try Fixture(limits: .init(replayWindow: 4))
        let grant = try await fixture.open()
        let attempt = UUID()
        for sequence: UInt64 in [1, 3, 2] {
            let call = try fixture.call(grant: grant, sequence: sequence, attempt: sequence == 2 ? attempt : UUID())
            _ = try await fixture.auth.accept(fixture.client.sign(call, maximumBytes: 10_000))
        }
        await failure(.replay) {
            _ = try await fixture.auth.accept(fixture.client.sign(fixture.call(grant: grant, sequence: 1), maximumBytes: 10_000))
        }
        await failure(.replay) {
            _ = try await fixture.auth.accept(fixture.client.sign(fixture.call(grant: grant, sequence: 4, attempt: attempt), maximumBytes: 10_000))
        }
        _ = try await fixture.auth.accept(fixture.client.sign(fixture.call(grant: grant, sequence: 9), maximumBytes: 10_000))
        await failure(.replay) {
            _ = try await fixture.auth.accept(fixture.client.sign(fixture.call(grant: grant, sequence: 2), maximumBytes: 10_000))
        }
    }

    @Test("an expired host nonce cannot be reused after its replay history is removed")
    func expiredSession() async throws {
        let clock = TestClock()
        let fixture = try Fixture(limits: .init(sessionLifetimeMilliseconds: 1_000), clock: clock)
        let old = try await fixture.open()
        clock.advance(.seconds(2))
        #expect(await fixture.auth.sessionCount() == 0)
        await failure(.sessionExpired) {
            _ = try await fixture.auth.accept(fixture.client.sign(fixture.call(grant: old), maximumBytes: 10_000))
        }
        let new = try await fixture.open()
        #expect(new.sessionID != old.sessionID)
        _ = try await fixture.auth.accept(fixture.client.sign(fixture.call(grant: new), maximumBytes: 10_000))
    }

    @Test("session admission is finite and retrying a hello does not allocate another session")
    func sessionCapacity() async throws {
        let fixture = try Fixture(limits: .init(maximumSessions: 2, maximumSessionsPerService: 1))
        let hello = fixture.hello()
        let first = try await fixture.auth.openSession(fixture.client.sign(hello, maximumBytes: 10_000))
        let same = try await fixture.auth.openSession(fixture.client.sign(hello, maximumBytes: 10_000))
        #expect(first.sessionID == same.sessionID)
        #expect(await fixture.auth.sessionCount() == 1)
        await failure(.overloaded) { _ = try await fixture.open() }
    }

    @Test("a user gateway cannot manufacture trusted moderation authority")
    func servicePermission() async throws {
        let fixture = try Fixture()
        let grant = try await fixture.open()
        let safety = V2RoomRequest.administration(.trustedSafety(.init(
            roomID: fixture.token.roomID, operationID: ModerationOperationID(uuid: UUID()),
            action: .redactMessage, messageID: MessageID(uuid: UUID()),
            expectedMessageRevision: 1, reasonCode: "safety"
        )))
        let rejected = try fixture.call(grant: grant, principal: .service, request: safety)
        await failure(.forbidden) {
            _ = try await fixture.auth.accept(fixture.client.sign(rejected, maximumBytes: 10_000))
        }
        let workerHello = fixture.hello(serviceID: fixture.worker.serviceID)
        let workerGrant = try await fixture.auth.openSession(fixture.worker.sign(workerHello, maximumBytes: 10_000))
        let accepted = try fixture.call(grant: workerGrant, principal: .service, request: safety)
        _ = try await fixture.auth.accept(fixture.worker.sign(accepted, maximumBytes: 10_000))
    }

    @Test("the host signing key, incarnation and attempt bind every reply")
    func replyBinding() async throws {
        let fixture = try Fixture()
        let grant = try await fixture.open()
        let call = try fixture.call(grant: grant)
        let reply = V2ActorAuthenticatedReply(call: call, response: .acknowledged)
        let good = try fixture.hostSigner.sign(reply, maximumBytes: 10_000)
        #expect(try fixture.trust.verifyReply(good, for: call, maximumBytes: 10_000) == .acknowledged)
        let falseHost = try fixture.client.sign(reply, maximumBytes: 10_000)
        #expect(throws: V2ActorAuthenticationError.wrongRecipient) {
            try fixture.trust.verifyReply(falseHost, for: call, maximumBytes: 10_000)
        }
        let otherAttempt = try fixture.call(grant: grant, attempt: UUID())
        #expect(throws: V2ActorAuthenticationError.wrongRecipient) {
            try fixture.trust.verifyReply(good, for: otherAttempt, maximumBytes: 10_000)
        }
        let hello = fixture.hello()
        let session = try await fixture.auth.openSession(fixture.client.sign(hello, maximumBytes: 10_000))
        let signedGrant = try fixture.hostSigner.sign(session, maximumBytes: 10_000)
        #expect(try fixture.trust.verifySessionGrant(signedGrant, for: hello, maximumBytes: 10_000) == session)
    }

    @Test("invitation control grants require the coordinator service permission")
    func invitationCoordinatorPermission() async throws {
        let fixture = try Fixture(workerPermissions: [.roomCoordination])
        let userGrant = try await fixture.open()
        let workerGrant = try await fixture.auth.openSession(fixture.worker.sign(
            fixture.hello(serviceID: fixture.worker.serviceID), maximumBytes: 10_000))
        let createdAt = Date()
        let creation = V2ActorInviteCreatePersistenceWire(inviteID: .init(uuid: UUID()),
            roomID: fixture.token.roomID, actorUserID: fixture.user, operationID: .init(uuid: UUID()),
            tokenDigest: .init(bytes: Data(repeating: 1, count: 32)), requestedLifetimeSeconds: 300,
            expiresAt: createdAt.addingTimeInterval(300), maximumApprovedUses: 10,
            maximumActiveInvitesPerRoom: 10, createdAt: createdAt, evaluatedAt: createdAt)
        let requests: [V2RoomRequest] = [.invitation(.commitCreation(creation)),
                                        .invitationQuery(.preflightCreation(creation))]
        for (index, request) in requests.enumerated() {
            for principal in [V2ActorCallPrincipal.user(fixture.user), .service] {
                let rejected = try fixture.call(grant: userGrant,
                    sequence: UInt64(index + 1), principal: principal, request: request)
                await failure(.forbidden) {
                    _ = try await fixture.auth.accept(fixture.client.sign(rejected, maximumBytes: 10_000))
                }
            }
            let accepted = try fixture.call(grant: workerGrant, sequence: UInt64(index + 1),
                principal: .service, request: request)
            _ = try await fixture.auth.accept(fixture.worker.sign(accepted, maximumBytes: 10_000))
        }
        let directCreate = V2RoomRequest.invitation(.create(.init(roomID: fixture.token.roomID,
            actorUserID: fixture.user, operationID: .init(uuid: UUID()), lifetime: 300, maximumApprovedUses: 10)))
        await failure(.forbidden) {
            _ = try await fixture.auth.accept(fixture.worker.sign(fixture.call(grant: workerGrant,
                sequence: 3, principal: .service, request: directCreate), maximumBytes: 10_000))
        }
    }

    @Test("wrong process incarnation, protocol and oversized payload fail before dispatch")
    func versionAndLimits() async throws {
        let fixture = try Fixture()
        let otherHost = V2ActorHostIdentity(hostID: fixture.token.host.hostID, incarnationID: UUID())
        let wrong = fixture.hello(recipient: otherHost)
        await failure(.wrongRecipient) {
            _ = try await fixture.auth.openSession(fixture.client.sign(wrong, maximumBytes: 10_000))
        }
        let future = V2ActorSessionHello(version: 2, serviceID: fixture.client.serviceID,
                                         callerIncarnation: UUID(), recipient: fixture.token.host, handshakeID: UUID())
        await failure(.unsupportedVersion) {
            _ = try await fixture.auth.openSession(fixture.client.sign(future, maximumBytes: 10_000))
        }
        await failure(.oversized) {
            _ = try await fixture.auth.accept(.init(signerID: fixture.client.serviceID,
                body: Data(repeating: 0, count: fixture.limits.maximumRequestBytes + 1), signature: Data()))
        }
        #expect(throws: V2ActorAuthenticationError.oversized) {
            try fixture.client.sign(fixture.hello(), maximumBytes: 1)
        }
    }

    private func failure(_ expected: V2ActorAuthenticationError, _ action: () async throws -> Void) async {
        do { try await action(); Issue.record("untrusted call unexpectedly passed") }
        catch { #expect(error as? V2ActorAuthenticationError == expected) }
    }

    private struct Fixture: Sendable {
        let token: V2RoomActivationToken
        let user = UserID(uuid: UUID())
        let client: V2ActorSigningIdentity
        let worker: V2ActorSigningIdentity
        let hostSigner: V2ActorSigningIdentity
        let trust: V2ActorTrustStore
        let limits: V2ActorAuthenticationLimits
        let auth: V2ActorSessionAuthenticator

        init(limits: V2ActorAuthenticationLimits = try! .init(), clock: TestClock = .init(),
             workerPermissions: Set<V2ActorServicePermission> = [.trustedSafety]) throws {
            self.limits = limits
            let host = V2ActorHostIdentity(hostID: V2ActorHostID(uuid: UUID()), incarnationID: UUID())
            token = .init(roomID: RoomID(uuid: UUID()), owner: try .init(shardID: "owner", epoch: 0),
                          activationEpoch: try .init(1), host: host)
            let clientKey = Curve25519.Signing.PrivateKey()
            let workerKey = Curve25519.Signing.PrivateKey()
            let hostKey = Curve25519.Signing.PrivateKey()
            client = try .init(serviceID: V2ActorServiceID("gateway"), privateKey: clientKey.rawRepresentation)
            worker = try .init(serviceID: V2ActorServiceID("reviewer"), privateKey: workerKey.rawRepresentation)
            hostSigner = try .init(serviceID: V2ActorServiceID("host"), privateKey: hostKey.rawRepresentation)
            trust = try .init(services: [
                .init(serviceID: client.serviceID, publicKey: clientKey.publicKey.rawRepresentation, permissions: [.userRoomCalls]),
                .init(serviceID: worker.serviceID, publicKey: workerKey.publicKey.rawRepresentation, permissions: workerPermissions),
                .init(serviceID: hostSigner.serviceID, publicKey: hostKey.publicKey.rawRepresentation, permissions: [], hostedIDs: [host.hostID]),
            ])
            auth = .init(host: host, trust: trust, limits: limits, now: { clock.now })
        }

        func hello(serviceID: V2ActorServiceID? = nil, recipient: V2ActorHostIdentity? = nil) -> V2ActorSessionHello {
            .init(serviceID: serviceID ?? client.serviceID, callerIncarnation: UUID(),
                  recipient: recipient ?? token.host, handshakeID: UUID())
        }

        func open() async throws -> V2ActorSessionGrant {
            try await auth.openSession(client.sign(hello(), maximumBytes: limits.maximumRequestBytes))
        }

        func call(grant: V2ActorSessionGrant, sequence: UInt64 = 1, attempt: UUID = UUID(),
                  principal: V2ActorCallPrincipal? = nil, request: V2RoomRequest? = nil) throws -> V2ActorAuthenticatedCall {
            .init(serviceID: grant.serviceID, callerIncarnation: grant.callerIncarnation, recipient: token.host,
                  sessionID: grant.sessionID, sequence: sequence, attemptID: attempt, traceID: UUID(),
                  remainingBudget: try .init(5_000), principal: principal ?? .user(user),
                  request: .invoke(token: token, request: request ?? .messaging(.send(.init(
                    roomID: token.roomID, actorUserID: user, clientMessageID: ClientMessageID(uuid: UUID()),
                    text: "signed", media: [], mentions: [], entities: [], replyTo: nil
                  )))))
        }
    }

    private final class TestClock: Sendable {
        private let value = Mutex(ContinuousClock.now)
        var now: ContinuousClock.Instant { value.withLock { $0 } }
        func advance(_ duration: Duration) { value.withLock { $0 += duration } }
    }
}
