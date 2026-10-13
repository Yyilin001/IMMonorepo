import Crypto
import Foundation
import IMV2ActorContracts
import IMV2Core
import Synchronization
import Testing
@testable import IMV2ActorCluster

@Suite("Signed actor sessions bind authority and reject replay")
struct V2ActorAuthenticationTests {
    @Test func macDomainsPreserveWireBinding() {
        #expect(V2ActorAuthenticatedCall.macDomain == Data(String(reflecting: V2ActorAuthenticatedCall.self).utf8))
        #expect(V2ActorAuthenticatedReply.macDomain == Data(String(reflecting: V2ActorAuthenticatedReply.self).utf8))
        #expect(RoomSubscriptionBatchCall.macDomain == Data(String(reflecting: RoomSubscriptionBatchCall.self).utf8))
        #expect(RoomSubscriptionBatchReply.macDomain == Data(String(reflecting: RoomSubscriptionBatchReply.self).utf8))
        #expect(RoomSubscriptionCall.macDomain == Data(String(reflecting: RoomSubscriptionCall.self).utf8))
        #expect(RoomSubscriptionReply.macDomain == Data(String(reflecting: RoomSubscriptionReply.self).utf8))
        #expect(JournalProjectionCall.macDomain == Data(String(reflecting: JournalProjectionCall.self).utf8))
        #expect(JournalProjectionReply.macDomain == Data(String(reflecting: JournalProjectionReply.self).utf8))
        #expect(RealtimeCall.macDomain == Data(String(reflecting: RealtimeCall.self).utf8))
        #expect(RealtimeReply.macDomain == Data(String(reflecting: RealtimeReply.self).utf8))
        #expect(ShardCall.macDomain == Data(String(reflecting: ShardCall.self).utf8))
        #expect(ShardReply.macDomain == Data(String(reflecting: ShardReply.self).utf8))
    }
    @Test("signed PB authenticates transmitted bytes independently of field order")
    func signedBodyKeyOrder() throws {
        struct Body: Codable, Equatable { let a: Int; let z: String }
        let key = Curve25519.Signing.PrivateKey()
        let serviceID = try V2ActorServiceID("key-order-test")
        let identity = try V2ActorSigningIdentity(serviceID: serviceID, privateKey: key.rawRepresentation)
        let trust = try V2ActorTrustStore(services: [try .init(serviceID: serviceID,
            publicKey: key.publicKey.rawRepresentation, permissions: [])])
        let value = Body(a: 1, z: "消息")
        let sorted = try V2ActorProtobuf.encode(value)
        var wire = try Im_Actor_V1_Value(serializedBytes: sorted)
        wire.objectValue.fields.reverse()
        let reversed = try wire.serializedData()
        for bytes in [sorted, reversed] {
            let packet = V2ActorSignedPacket(signerID: serviceID, body: bytes,
                signature: try key.signature(for: bytes))
            #expect(try trust.verify(packet, as: Body.self, maximumBytes: 1_024).0 == value)
        }
        let packet = try identity.sign(value, maximumBytes: 1_024)
        #expect(try trust.verify(packet, as: Body.self, maximumBytes: 1_024).0 == value)
        let altered = V2ActorSignedPacket(signerID: serviceID, body: reversed,
            signature: try key.signature(for: sorted))
        #expect(throws: V2ActorAuthenticationError.invalidSignature) {
            try trust.verify(altered, as: Body.self, maximumBytes: 1_024)
        }
    }

    @Test("remote forward pairs require coordination service authority and exact target host", arguments: [false, true])
    func forwardPairAuthority(allowed: Bool) async throws {
        let fixture = try Fixture(clientPermissions: allowed ? [.roomCoordination] : [.userRoomCalls, .policyMutation])
        let grant = try await fixture.open()
        let pair = V2ActorForwardPairWire(actorUserID: fixture.user, operationID: .init(uuid: UUID()),
            source: try .init(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID()), revision: .init(1)),
            targetRoomID: fixture.token.roomID)
        func packet(_ pair: V2ActorForwardPairWire, principal: V2ActorCallPrincipal, sequence: UInt64) throws -> V2ActorSignedPacket {
            try fixture.client.sign(V2ActorAuthenticatedCall(serviceID: grant.serviceID,
                callerIncarnation: grant.callerIncarnation, recipient: fixture.token.host,
                sessionID: grant.sessionID, sequence: sequence, attemptID: UUID(), traceID: UUID(),
                remainingBudget: .init(5_000), principal: principal,
                request: .forwardPair(token: fixture.token, pair: pair)), maximumBytes: 10_000)
        }
        await failure(.forbidden) { _ = try await fixture.auth.accept(packet(pair, principal: .user(fixture.user), sequence: 1)) }
        let valid = try packet(pair, principal: .service, sequence: 2)
        if allowed {
            #expect(try await fixture.auth.accept(valid).call.request == .forwardPair(token: fixture.token, pair: pair))
            await failure(.replay) { _ = try await fixture.auth.accept(valid) }
            let wrongTarget = V2ActorForwardPairWire(actorUserID: pair.actorUserID, operationID: pair.operationID,
                source: pair.source, targetRoomID: .init(uuid: UUID()))
            await failure(.wrongRecipient) { _ = try await fixture.auth.accept(packet(wrongTarget, principal: .service, sequence: 3)) }
        } else { await failure(.forbidden) { _ = try await fixture.auth.accept(valid) } }
    }
    @Test("room policy endpoint pins stable host and preserves exact physical alias")
    func roomPolicyEndpointLocator() throws {
        let host = UUID()
        let locator = try V2RoomPolicyEndpointLocator(hostID: host, shardID: "room:共享/primary")
        #expect(try V2RoomPolicyEndpointLocator(encoded: locator.encoded) == locator)
        #expect(locator.encoded.utf8.count <= 512)
        for invalid in ["room-b", locator.encoded + ":extra",
                        locator.encoded.replacingOccurrences(of: host.uuidString.lowercased(), with: host.uuidString.uppercased()),
                        "policy-room-v1:" + host.uuidString.lowercased() + ":@@"] {
            #expect(throws: (any Error).self) { try V2RoomPolicyEndpointLocator(encoded: invalid) }
        }
        #expect(throws: (any Error).self) { try V2RoomPolicyEndpointLocator(hostID: host, shardID: "a\nb") }
        #expect(throws: (any Error).self) { try V2RoomPolicyEndpointLocator(hostID: host, shardID: String(repeating: "x", count: 129)) }
    }

    @Test("versioned policy updates require mutation authority", arguments: [false, true])
    func versionedPolicyUpdateAuthority(allowed: Bool) async throws {
        let source = V2ActorHostIdentity(hostID: .init(uuid: UUID()), incarnationID: UUID())
        let fixture = try Fixture(clientHostedIDs: [source.hostID], clientPermissions: allowed ? [.policyMutation] : [.policyRegistration])
        let grant = try await fixture.open()
        let scope = V2PolicyScopeWire(account: UUID())
        let snapshot = try V2PolicySnapshotWire(scope: scope, version: 2, facts: .account(.init(userID: scope.first, isActive: true)))
        let request = V2ActorRPCRequest.updatePolicySnapshot(try .init(endpoint: "owner",
            session: .init(source: source, recipient: fixture.token.host, generation: 1),
            sequence: 1, payload: .snapshot(snapshot)))
        func call(_ principal: V2ActorCallPrincipal, sequence: UInt64) throws -> V2ActorAuthenticatedCall {
            .init(serviceID: grant.serviceID, callerIncarnation: grant.callerIncarnation, recipient: fixture.token.host,
                sessionID: grant.sessionID, sequence: sequence, attemptID: UUID(), traceID: UUID(),
                remainingBudget: try .init(5_000), principal: principal, request: request)
        }
        await failure(.forbidden) { _ = try await fixture.auth.accept(fixture.client.sign(call(.user(fixture.user), sequence: 1), maximumBytes: 10_000)) }
        let packet = try fixture.client.sign(call(.service, sequence: 2), maximumBytes: 10_000)
        if allowed { #expect(try await fixture.auth.accept(packet).call.request == request) }
        else { await failure(.forbidden) { _ = try await fixture.auth.accept(packet) } }
    }
    @Test("policy registration permission cannot subscribe another host")
    func versionedPolicySubscriberIdentity() async throws {
        let fixture = try Fixture(clientPermissions: [.policyRegistration]), grant = try await fixture.open()
        let request = V2ActorRPCRequest.policySnapshots(try .init(endpoint: "owner", scopes: [.init(account: UUID())],
            subscriber: .init(host: fixture.token.host, endpoint: "gateway")))
        let call = V2ActorAuthenticatedCall(serviceID: grant.serviceID, callerIncarnation: grant.callerIncarnation,
            recipient: fixture.token.host, sessionID: grant.sessionID, sequence: 1, attemptID: UUID(), traceID: UUID(),
            remainingBudget: try .init(5_000), principal: .service, request: request)
        await failure(.forbidden) { _ = try await fixture.auth.accept(fixture.client.sign(call, maximumBytes: 10_000)) }
    }

    @Test("policy registration requires independent service authority", arguments: [false, true])
    func policyRegistrationAuthority(allowed: Bool) async throws {
        let subscriberID = V2ActorHostID(uuid: UUID())
        let fixture = try Fixture(clientHostedIDs: [subscriberID], clientPermissions: allowed ? [.policyRegistration] : [.policyMutation, .roomCoordination])
        let grant = try await fixture.open()
        let scope = V2PolicyScopeWire(account: UUID())
        let claim = try V2PolicySnapshotRequestWire(endpoint: "owner", scopes: [scope],
            subscriber: .init(host: .init(hostID: subscriberID, incarnationID: UUID()), endpoint: "gateway"))
        func call(_ principal: V2ActorCallPrincipal, sequence: UInt64) throws -> V2ActorAuthenticatedCall {
            .init(serviceID: grant.serviceID, callerIncarnation: grant.callerIncarnation, recipient: fixture.token.host,
                sessionID: grant.sessionID, sequence: sequence, attemptID: UUID(), traceID: UUID(),
                remainingBudget: try .init(5_000), principal: principal, request: .policySnapshots(claim))
        }
        await failure(.forbidden) {
            _ = try await fixture.auth.accept(fixture.client.sign(call(.user(fixture.user), sequence: 1), maximumBytes: 10_000))
        }
        let packet = try fixture.client.sign(call(.service, sequence: 2), maximumBytes: 10_000)
        if allowed {
            #expect(try await fixture.auth.accept(packet).call.request == .policySnapshots(claim))
            await failure(.replay) { _ = try await fixture.auth.accept(packet) }
            let activation = V2ActorAuthenticatedCall(serviceID: grant.serviceID, callerIncarnation: grant.callerIncarnation,
                recipient: fixture.token.host, sessionID: grant.sessionID, sequence: 3, attemptID: UUID(), traceID: UUID(),
                remainingBudget: try .init(5_000), principal: .service,
                request: .activate(roomID: fixture.token.roomID, owner: fixture.token.owner))
            await failure(.forbidden) {
                _ = try await fixture.auth.accept(fixture.client.sign(activation, maximumBytes: 10_000))
            }
        } else { await failure(.forbidden) { _ = try await fixture.auth.accept(packet) } }
    }

    @Test("policy mutation requires independent service authority", arguments: [false, true])
    func policyMutationAuthority(allowed: Bool) async throws {
        let fixture = try Fixture(clientPermissions: allowed ? [.policyMutation] : [.policyRegistration])
        let grant = try await fixture.open()
        let request = try V2PolicyMutationWire(endpoint: "owner", scope: .init(account: UUID()),
            operationKey: "operation", fingerprint: Data(repeating: 1, count: 32), command: .disable(.init(userID: UUID(), operationID: UUID(), reason: "user_requested", operatorPrincipal: "test")))
        func call(_ principal: V2ActorCallPrincipal, sequence: UInt64) throws -> V2ActorAuthenticatedCall {
            .init(serviceID: grant.serviceID, callerIncarnation: grant.callerIncarnation, recipient: fixture.token.host,
                sessionID: grant.sessionID, sequence: sequence, attemptID: UUID(), traceID: UUID(),
                remainingBudget: try .init(5_000), principal: principal, request: .mutatePolicy(request))
        }
        await failure(.forbidden) {
            _ = try await fixture.auth.accept(fixture.client.sign(call(.user(fixture.user), sequence: 1), maximumBytes: 10_000))
        }
        let packet = try fixture.client.sign(call(.service, sequence: 2), maximumBytes: 10_000)
        if allowed {
            #expect(try await fixture.auth.accept(packet).call.request == .mutatePolicy(request))
            await failure(.replay) { _ = try await fixture.auth.accept(packet) }
            let activation = V2ActorAuthenticatedCall(serviceID: grant.serviceID, callerIncarnation: grant.callerIncarnation,
                recipient: fixture.token.host, sessionID: grant.sessionID, sequence: 3, attemptID: UUID(), traceID: UUID(),
                remainingBudget: try .init(5_000), principal: .service,
                request: .activate(roomID: fixture.token.roomID, owner: fixture.token.owner))
            await failure(.forbidden) {
                _ = try await fixture.auth.accept(fixture.client.sign(activation, maximumBytes: 10_000))
            }
        } else { await failure(.forbidden) { _ = try await fixture.auth.accept(packet) } }
        let receipt = try V2PolicyMutationReceiptWire(scope: request.scope, operationKey: request.operationKey,
            fingerprint: request.fingerprint, receipt: .disable(.init(kind: .disabled, disabledAt: Date())), replayed: false)
        #expect(receipt.matches(request))
        let other = try V2PolicyMutationWire(endpoint: request.endpoint, scope: request.scope,
            operationKey: "other", fingerprint: request.fingerprint, command: request.command)
        #expect(!receipt.matches(other))
    }

    @Test("policy scope decoding canonicalizes pairs and rejects duplicate snapshot scopes")
    func policyOwnershipCodec() throws {
        let a = UUID(), b = UUID()
        let forward = try V2PolicyScopeWire(pair: a, b), reverse = try V2PolicyScopeWire(pair: b, a)
        #expect(forward == reverse)
        #expect(try V2ActorProtobuf.decode(V2PolicyScopeWire.self, from: V2ActorProtobuf.encode(reverse)) == forward)
        #expect(throws: (any Error).self) { try V2PolicyScopeWire(pair: a, a) }
        #expect(throws: (any Error).self) { try V2PolicySnapshotRequestWire(endpoint: "owner", scopes: [forward, reverse],
            subscriber: .init(host: .init(hostID: .init(uuid: UUID()), incarnationID: UUID()), endpoint: "gateway")) }
        var object = try V2ActorProtobuf.message(V2PolicyScopeWire(account: a))
        var extra = Im_Actor_V1_Field(); extra.name = "second"; extra.value = try V2ActorProtobuf.message(b)
        object.objectValue.fields.append(extra)
        #expect(throws: (any Error).self) {
            try V2ActorProtobuf.decode(V2PolicyScopeWire.self, from: object.serializedData())
        }
        #expect(throws: (any Error).self) {
            try V2PolicySnapshotWire(scope: forward, version: 0, facts: .pair(.init(blocked: false, isFriend: false)))
        }
    }

    @Test("policy snapshot decoding validates durable versions and fact size")
    func policySnapshotWireBounds() throws {
        let scope = V2PolicyScopeWire(account: UUID())
        let wire = try V2PolicySnapshotWire(scope: scope, version: 1, facts: .account(.init(userID: scope.first, isActive: true)))
        #expect(try V2ActorProtobuf.decode(V2PolicySnapshotWire.self, from: V2ActorProtobuf.encode(wire)) == wire)
        for version: Int64 in [0, -1] {
            #expect(throws: (any Error).self) { try V2PolicySnapshotWire(scope: scope, version: version, facts: .account(.init(userID: scope.first, isActive: true))) }
        }
        #expect(throws: (any Error).self) { try V2PolicySnapshotWire(scope: scope, version: 1, facts: .pair(.init(blocked: false, isFriend: false))) }
        #expect(throws: (any Error).self) { try V2PolicySnapshotWire(scope: scope, version: 1, facts: .account(.init(userID: scope.first, isActive: true, specialKind: String(repeating: "x", count: 16_385)))) }
        var object = try V2ActorProtobuf.message(wire)
        let index = try #require(object.objectValue.fields.firstIndex { $0.name == "version" })
        object.objectValue.fields[index].value.signedValue = 0
        #expect(throws: (any Error).self) {
            try V2ActorProtobuf.decode(V2PolicySnapshotWire.self, from: object.serializedData())
        }
    }


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



    @Test("room subscription binds user and Gateway callback to authenticated service incarnation")
    func roomSubscriptionAuthority() async throws {
        let fixture = try Fixture(clientPermissions: [.userRoomCalls, .realtimeReceive], gatewayNodeIDs: ["gateway-alias"])
        let grant = try await fixture.open()
        func descriptor(service: String = "gateway", node: String = "gateway-alias",
                        incarnation: UUID? = nil) -> V2GatewayRealtimeDescriptor {
            .init(identity: .init(nodeID: node, serviceID: service, incarnationID: incarnation ?? grant.callerIncarnation),
                endpointReference: Data("signed-reference".utf8), address: "127.0.0.1", port: 12_345)
        }
        func request(_ target: V2GatewayRealtimeDescriptor, user: UserID? = nil) -> V2RoomRequest {
            .roomSubscription(.subscribe(.init(roomID: fixture.token.roomID, actorUserID: user ?? fixture.user,
                gatewayDescriptor: target)))
        }
        let subscribe = request(descriptor())
        _ = try await fixture.auth.accept(fixture.client.sign(fixture.call(grant: grant,
            request: subscribe), maximumBytes: 16_384))
        #expect(subscribe.replayPolicy == .noAutomaticRetry && !subscribe.hasStableOperationID)
        for target in [descriptor(service: "other"), descriptor(node: "other"), descriptor(incarnation: UUID())] {
            await failure(.forbidden) {
                _ = try await fixture.auth.accept(fixture.client.sign(fixture.call(grant: grant,
                    sequence: 2, request: request(target)), maximumBytes: 16_384))
            }
        }
        await failure(.forbidden) {
            _ = try await fixture.auth.accept(fixture.client.sign(fixture.call(grant: grant, sequence: 2,
                request: request(descriptor(), user: UserID(uuid: UUID()))), maximumBytes: 16_384))
        }
        await failure(.forbidden) {
            _ = try await fixture.auth.accept(fixture.client.sign(fixture.call(grant: grant, sequence: 2,
                principal: .service, request: subscribe), maximumBytes: 16_384))
        }
        let fence = V2RoomSubscriptionFence(activation: fixture.token, subscriptionID: UUID(), generation: 1, baselineSequence: 5)
        let activation = V2RoomRequest.roomSubscription(.activate(.init(roomID: fixture.token.roomID,
            actorUserID: fixture.user, gatewayDescriptor: descriptor(), fence: fence)))
        _ = try await fixture.auth.accept(fixture.client.sign(fixture.call(grant: grant, sequence: 2,
            request: activation), maximumBytes: 16_384))
        let otherToken = V2RoomActivationToken(roomID: fixture.token.roomID, owner: fixture.token.owner,
            activationEpoch: try .init(2), host: fixture.token.host)
        let otherFence = V2RoomSubscriptionFence(activation: otherToken, subscriptionID: UUID(), generation: 1, baselineSequence: 5)
        await failure(.wrongRecipient) {
            let wrong = V2RoomRequest.roomSubscription(.activate(.init(roomID: fixture.token.roomID,
                actorUserID: fixture.user, gatewayDescriptor: descriptor(), fence: otherFence)))
            _ = try await fixture.auth.accept(fixture.client.sign(fixture.call(grant: grant, sequence: 3,
                request: wrong), maximumBytes: 16_384))
        }
        let reset = V2RoomRequest.roomSubscription(.reset(.init(roomID: fixture.token.roomID,
            actorUserID: fixture.user, gatewayDescriptor: descriptor(), expectedFence: fence)))
        _ = try await fixture.auth.accept(fixture.client.sign(fixture.call(grant: grant, sequence: 3,
            request: reset), maximumBytes: 16_384))
        await failure(.wrongRecipient) {
            let wrongReset = V2RoomRequest.roomSubscription(.reset(.init(roomID: fixture.token.roomID,
                actorUserID: fixture.user, gatewayDescriptor: descriptor(), expectedFence: otherFence)))
            _ = try await fixture.auth.accept(fixture.client.sign(fixture.call(grant: grant, sequence: 4,
                request: wrongReset), maximumBytes: 16_384))
        }
        await failure(.forbidden) {
            _ = try await fixture.auth.accept(fixture.client.sign(fixture.call(grant: grant, sequence: 4,
                principal: .service, request: reset), maximumBytes: 16_384))
        }
        #expect(try V2ActorProtobuf.decode(V2RoomRequest.self, from: V2ActorProtobuf.encode(reset)) == reset)
        let unsubscribe = V2RoomRequest.roomSubscription(.unsubscribe(.init(roomID: fixture.token.roomID,
            actorUserID: fixture.user, gatewayDescriptor: descriptor(), memberRevision: 0)))
        _ = try await fixture.auth.accept(fixture.client.sign(fixture.call(grant: grant, sequence: 4,
            request: unsubscribe), maximumBytes: 16_384))
        let response = V2RoomResponse.roomSubscription(.granted(.init(fence: fence, memberRevision: 0,
            userBaselineSequence: 7, deliverySession: .init(host: fixture.token.host, gateway: descriptor().identity, generation: 1))))
        #expect(try V2ActorProtobuf.decode(V2RoomResponse.self, from: V2ActorProtobuf.encode(response)) == response)
        #expect(try V2ActorProtobuf.decode(V2RoomRequest.self, from: V2ActorProtobuf.encode(activation)) == activation)
        let missingReceiverPermission = try Fixture()
        let missingGrant = try await missingReceiverPermission.open()
        let target = V2GatewayRealtimeDescriptor(identity: .init(nodeID: "gateway", serviceID: "gateway",
            incarnationID: missingGrant.callerIncarnation), endpointReference: Data([1]), address: "127.0.0.1", port: 12_345)
        await failure(.forbidden) {
            let rejected = V2RoomRequest.roomSubscription(.subscribe(.init(roomID: missingReceiverPermission.token.roomID,
                actorUserID: missingReceiverPermission.user, gatewayDescriptor: target)))
            _ = try await missingReceiverPermission.auth.accept(missingReceiverPermission.client.sign(
                missingReceiverPermission.call(grant: missingGrant, request: rejected), maximumBytes: 16_384))
        }
    }

    @Test("host publisher resolution uses only unique configured trust and required permissions")
    func configuredHostPublisher() throws {
        let fixture = try Fixture()
        #expect(try fixture.trust.configuredHostServiceID(for: fixture.token.host.hostID) == fixture.hostSigner.serviceID)
        #expect(throws: V2ActorAuthenticationError.forbidden) {
            try fixture.trust.configuredHostServiceID(for: fixture.token.host.hostID, requiring: [.realtimePublish])
        }
        #expect(throws: V2ActorAuthenticationError.forbidden) {
            try fixture.trust.configuredHostServiceID(for: V2ActorHostID(uuid: UUID()))
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

    @Test("maintenance requires its own service permission and never a user principal")
    func maintenancePermission() async throws {
        let fixture = try Fixture(workerPermissions: [.roomMaintenance])
        let request = V2RoomRequest.maintenance(.trimLog(.init(roomID: fixture.token.roomID,
            mode: .window, windowSeconds: 86_400)))
        #expect(request.replayPolicy == .noAutomaticRetry)
        #expect(!request.hasStableOperationID)
        let userGrant = try await fixture.open()
        await failure(.forbidden) {
            _ = try await fixture.auth.accept(fixture.client.sign(
                fixture.call(grant: userGrant, principal: .service, request: request), maximumBytes: 10_000))
        }
        let workerGrant = try await fixture.auth.openSession(fixture.worker.sign(
            fixture.hello(serviceID: fixture.worker.serviceID), maximumBytes: 10_000))
        await failure(.forbidden) {
            _ = try await fixture.auth.accept(fixture.worker.sign(
                fixture.call(grant: workerGrant, principal: .user(fixture.user), request: request), maximumBytes: 10_000))
        }
        _ = try await fixture.auth.accept(fixture.worker.sign(
            fixture.call(grant: workerGrant, sequence: 2, principal: .service, request: request), maximumBytes: 10_000))
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

    @Test("invitation metadata requires coordinator authority while frozen operations bind the user")
    func invitationCoordinatorPermission() async throws {
        let fixture = try Fixture(workerPermissions: [.roomCoordination])
        let userGrant = try await fixture.open()
        let workerGrant = try await fixture.auth.openSession(fixture.worker.sign(
            fixture.hello(serviceID: fixture.worker.serviceID), maximumBytes: 10_000))
        let createdAt = Date(), milliseconds = UInt64(Date().timeIntervalSince1970 * 1_000)
        let operation = GroupInviteOperationID(uuid: UUID())
        let intent = try V2GroupInvitationOperationIntent(identity: .init(accountID: fixture.user,
            scope: .room(fixture.token.roomID), operation: .groupInvite(operation)),
            action: .create(lifetimeSeconds: 300, maximumApprovedUses: 10, expectedMembershipRevision: 0),
            confirmedUntilMilliseconds: milliseconds + 120_000)
        let admission = try V2GroupInvitationAdmission(id: .init(uuid: UUID()), identity: intent.identity,
            intentFingerprint: intent.fingerprint, membershipRevision: 0,
            issuedAtMilliseconds: milliseconds, expiresAtMilliseconds: milliseconds + 120_000)
        let command = try V2GroupInvitationOperationCommand(intent: intent, admission: admission)
        let requests: [V2RoomRequest] = [.administration(.groupInvitationAdmit(intent)),
            .administration(.groupInvitationSubmit(.init(command: command))),
            .administration(.groupInvitationRecover(.init(intent: intent, action: .query)))]
        for (index, request) in requests.enumerated() {
            _ = try await fixture.auth.accept(fixture.client.sign(fixture.call(grant: userGrant,
                sequence: UInt64(index + 1), principal: .user(fixture.user), request: request), maximumBytes: 10_000))
            await failure(.forbidden) {
                _ = try await fixture.auth.accept(fixture.worker.sign(fixture.call(grant: workerGrant,
                    sequence: UInt64(index + 1), principal: .service, request: request), maximumBytes: 10_000))
            }
        }
        let creation = V2ActorInviteCreatePersistenceWire(inviteID: .init(uuid: UUID()),
            roomID: fixture.token.roomID, actorUserID: fixture.user, operationID: operation,
            tokenDigest: .init(bytes: Data(repeating: 1, count: 32)), requestedLifetimeSeconds: 300,
            expiresAt: createdAt.addingTimeInterval(300), maximumApprovedUses: 10,
            maximumActiveInvitesPerRoom: 10, createdAt: createdAt, evaluatedAt: createdAt)
        let metadata = V2RoomRequest.invitationQuery(.preflightCreation(creation))
        for principal in [V2ActorCallPrincipal.user(fixture.user), .service] {
            await failure(.forbidden) {
                _ = try await fixture.auth.accept(fixture.client.sign(fixture.call(grant: userGrant,
                    sequence: 4, principal: principal, request: metadata), maximumBytes: 10_000))
            }
        }
        _ = try await fixture.auth.accept(fixture.worker.sign(fixture.call(grant: workerGrant,
            sequence: 4, principal: .service, request: metadata), maximumBytes: 10_000))
    }

    @Test("forward workflow commands require service authority and pairs require reservations")
    func forwardingAuthority() async throws {
        let fixture = try Fixture(workerPermissions: [.roomCoordination])
        let source = V2ForwardMessageReference(roomID: fixture.token.roomID,
            messageID: .init(uuid: UUID()), revision: try .init(1))
        let request = V2RoomRequest.forward(.prepareExport(.init(actorUserID: fixture.user,
            operationID: .init(uuid: UUID()), source: source, targetRoomID: .init(uuid: UUID()),
            targetShardID: "target", targetEpoch: 0)))
        let userGrant = try await fixture.open()
        await failure(.forbidden) {
            _ = try await fixture.auth.accept(fixture.client.sign(fixture.call(grant: userGrant,
                principal: .user(fixture.user), request: request), maximumBytes: 10_000))
        }
        let workerGrant = try await fixture.auth.openSession(fixture.worker.sign(
            fixture.hello(serviceID: fixture.worker.serviceID), maximumBytes: 10_000))
        await failure(.forbidden) {
            _ = try await fixture.auth.accept(fixture.worker.sign(fixture.call(grant: workerGrant,
                principal: .user(fixture.user), request: request), maximumBytes: 10_000))
        }
        _ = try await fixture.auth.accept(fixture.worker.sign(fixture.call(grant: workerGrant,
            sequence: 2, principal: .service, request: request), maximumBytes: 10_000))
        let pair = V2RoomRequest.forward(.sameOwnerPair(.init(actorUserID: fixture.user,
            operationID: .init(uuid: UUID()), source: source, targetRoomID: fixture.token.roomID)))
        await failure(.forbidden) {
            _ = try await fixture.auth.accept(fixture.worker.sign(fixture.call(grant: workerGrant,
                sequence: 3, principal: .service, request: pair), maximumBytes: 10_000))
        }
    }

    @Test("a signed user reader-candidate query passes actor session admission")
    func readerCandidateAdmission() async throws {
        let fixture = try Fixture()
        let grant = try await fixture.open()
        let query = try V2ActorReadReceiptReadersQueryWire(roomID: fixture.token.roomID,
            messageID: .init(uuid: UUID()), actorUserID: fixture.user, cursor: nil, pageSize: 10)
        _ = try await fixture.auth.accept(fixture.client.sign(fixture.call(grant: grant,
            request: .receiptQuery(.readerCandidates(query))), maximumBytes: 10_000))
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

    @Test("a local capability requires a signed hello and shares principal, replay, generation and expiry checks")
    func localCapabilityChecks() async throws {
        let clock = TestClock()
        let fixture = try Fixture(limits: .init(sessionLifetimeMilliseconds: 1_000), clock: clock)
        let generation = UUID()
        let hello = fixture.hello()
        let helloPacket = try fixture.client.sign(hello, maximumBytes: fixture.limits.maximumRequestBytes)
        var tampered = helloPacket.body
        tampered[tampered.startIndex] ^= 1
        await failure(.invalidSignature) {
            _ = try await fixture.auth.openLocalSession(.init(signerID: helloPacket.signerID,
                body: tampered, signature: helloPacket.signature), generation: generation)
        }
        let (grant, capability) = try await fixture.auth.openLocalSession(
            helloPacket, generation: generation)
        let first = try fixture.call(grant: grant)
        let otherIssuer = V2ActorSessionAuthenticator(host: fixture.token.host,
            trust: fixture.trust, limits: fixture.limits, now: { clock.now })
        await failure(.wrongRecipient) {
            _ = try await otherIssuer.acceptLocal(V2ActorLocalPayload(first),
                capability: capability, generation: generation)
        }
        #expect(try await fixture.auth.acceptLocal(V2ActorLocalPayload(first), capability: capability,
                                                   generation: generation).call == first)
        await failure(.replay) {
            _ = try await fixture.auth.acceptLocal(V2ActorLocalPayload(first), capability: capability,
                                                   generation: generation)
        }
        await failure(.forbidden) {
            _ = try await fixture.auth.acceptLocal(V2ActorLocalPayload(try fixture.call(grant: grant,
                sequence: 2, principal: .user(UserID(uuid: UUID())))),
                capability: capability, generation: generation)
        }
        await failure(.wrongRecipient) {
            _ = try await fixture.auth.acceptLocal(V2ActorLocalPayload(try fixture.call(
                grant: grant, sequence: 2)),
                                                   capability: capability, generation: UUID())
        }
        _ = try await fixture.auth.acceptLocal(V2ActorLocalPayload(try fixture.call(
            grant: grant, sequence: 2)),
                                               capability: capability, generation: generation)
        clock.advance(.seconds(2))
        await failure(.sessionExpired) {
            _ = try await fixture.auth.acceptLocal(V2ActorLocalPayload(try fixture.call(
                grant: grant, sequence: 3)),
                                                   capability: capability, generation: generation)
        }
    }

    @Test("local typed admission retains the signed-body byte ceiling and reply binding")
    func localSizeAndReplyBinding() async throws {
        let limits = try V2ActorAuthenticationLimits(maximumRequestBytes: 4_096)
        let fixture = try Fixture(limits: limits)
        let generation = UUID()
        let hello = fixture.hello()
        let (grant, capability) = try await fixture.auth.openLocalSession(
            fixture.client.sign(hello, maximumBytes: limits.maximumRequestBytes),
            generation: generation)
        let large = try V2RoomRequest.messaging(.sendOperation(try .init(command: try .init(
            roomID: fixture.token.roomID, senderUserID: fixture.user,
            clientMessageID: .init(uuid: UUID()), text: String(repeating: "x", count: 4_096),
            media: [], mentions: [], entities: [], replyTo: nil, limits: .init(maxUTF8Bytes: 65_536)), firstSubmissionDeadlineMilliseconds: 1_900_000_000_000)))
        await failure(.oversized) {
            _ = try await fixture.auth.acceptLocal(V2ActorLocalPayload(try fixture.call(
                grant: grant, request: large)),
                                                   capability: capability, generation: generation)
        }
        let call = try fixture.call(grant: grant)
        _ = try await fixture.auth.acceptLocal(V2ActorLocalPayload(call),
                                               capability: capability, generation: generation)
        let reply = V2ActorAuthenticatedReply(call: call, response: .acknowledged)
        #expect(try fixture.trust.verifyLocalReply(V2ActorLocalPayload(reply), for: call,
            from: fixture.token.host, maximumBytes: limits.maximumReplyBytes) == .acknowledged)
        let measuredReply = try V2ActorLocalPayload(reply)
        #expect(throws: V2ActorAuthenticationError.oversized) {
            try fixture.trust.verifyLocalReply(measuredReply, for: call,
                from: fixture.token.host, maximumBytes: measuredReply.byteCount - 1)
        }
        #expect(throws: V2ActorAuthenticationError.wrongRecipient) {
            try fixture.trust.verifyLocalReply(V2ActorLocalPayload(reply), for: try fixture.call(
                grant: grant, attempt: UUID()), from: fixture.token.host,
                maximumBytes: limits.maximumReplyBytes)
        }
    }

    @Test("binary authenticated calls preserve session authority, replay and expiry", arguments: [false, true])
    func binarySessionAdmission(binary: Bool) async throws {
        let clock = TestClock()
        let fixture = try Fixture(limits: .init(sessionLifetimeMilliseconds: 1_000), clock: clock)
        let grant = try await fixture.open()
        let call = try fixture.call(grant: grant)
        func changed(version: Int = 1, recipient: V2ActorHostIdentity? = nil,
                     trace: UUID? = nil, caller: UUID? = nil) -> V2ActorAuthenticatedCall {
            .init(version: version, serviceID: call.serviceID, callerIncarnation: caller ?? call.callerIncarnation,
                recipient: recipient ?? call.recipient, sessionID: call.sessionID, sequence: call.sequence,
                attemptID: call.attemptID, traceID: trace ?? call.traceID, remainingBudget: call.remainingBudget,
                principal: call.principal, request: call.request)
        }
        await failure(.unsupportedVersion) {
            _ = try await fixture.auth.accept(fixture.client.sign(changed(version: 2),
                maximumBytes: 65_536))
        }
        await failure(.wrongRecipient) {
            _ = try await fixture.auth.accept(fixture.client.sign(changed(recipient:
                .init(hostID: call.recipient.hostID, incarnationID: UUID())), maximumBytes: 65_536))
        }
        await failure(.sessionExpired) {
            _ = try await fixture.auth.accept(fixture.client.sign(changed(caller: UUID()),
                maximumBytes: 65_536))
        }
        let packet = try fixture.client.sign(call, maximumBytes: 65_536)
        #expect(try await fixture.auth.accept(packet).call == call)
        await failure(.replay) { _ = try await fixture.auth.accept(packet) }
        let forbidden = try fixture.call(grant: grant, sequence: 2, principal: .service)
        await failure(.forbidden) {
            _ = try await fixture.auth.accept(fixture.client.sign(forbidden,
                maximumBytes: 65_536))
        }
        clock.advance(.milliseconds(1_001))
        await failure(.sessionExpired) {
            _ = try await fixture.auth.accept(fixture.client.sign(fixture.call(grant: grant, sequence: 3),
                maximumBytes: 65_536))
        }
    }

    @Test("session MAC preserves authority, direction, replay, expiry and forbids signed downgrade")
    func sessionMACAdmission() async throws {
        let clock = TestClock()
        let fixture = try Fixture(limits: .init(sessionLifetimeMilliseconds: 1_000), clock: clock)
        let agreement = Curve25519.KeyAgreement.PrivateKey()
        let hello = V2ActorSessionHello(serviceID: fixture.client.serviceID, callerIncarnation: UUID(),
            recipient: fixture.token.host, handshakeID: UUID(), agreementKey: agreement.publicKey.rawRepresentation)
        let grant = try await fixture.auth.openSession(fixture.client.sign(hello, maximumBytes: 16_384))
        let repeated = try await fixture.auth.openSession(fixture.client.sign(hello, maximumBytes: 16_384))
        #expect(repeated.sessionID == grant.sessionID && repeated.agreementKey == grant.agreementKey)
        let mac = try V2ActorSessionMAC(privateKey: agreement, peerKey: #require(grant.agreementKey),
            transcript: V2ActorProtobuf.encode(hello), sessionID: grant.sessionID,
            client: fixture.client.serviceID, server: fixture.hostSigner.serviceID)
        let call = try fixture.call(grant: grant)
        let packet = try mac.seal(call, reply: false, maximumBytes: 65_536)
        #expect(packet.signature.count == 32)
        var changed = packet.body; changed[changed.count - 1] ^= 1
        await failure(.invalidSignature) {
            _ = try await fixture.auth.accept(.init(signerID: packet.signerID, body: changed, signature: packet.signature))
        }
        await failure(.invalidSignature) { _ = try await fixture.auth.accept(fixture.client.sign(call, maximumBytes: 65_536)) }
        await failure(.wrongRecipient) {
            _ = try await fixture.auth.accept(.init(signerID: fixture.worker.serviceID, body: packet.body, signature: packet.signature))
        }
        let verified = try await fixture.auth.accept(packet)
        #expect(verified.call == call)
        await failure(.replay) { _ = try await fixture.auth.accept(packet) }
        let reply = V2ActorAuthenticatedReply(call: call, response: .acknowledged)
        let response = try #require(verified.sessionMAC).seal(reply, reply: true, maximumBytes: 65_536)
        let decoded = try mac.open(response, as: V2ActorAuthenticatedReply.self, reply: true, maximumBytes: 65_536)
        #expect(try fixture.trust.verifyReplyBinding(decoded, for: call) == .acknowledged)
        #expect(throws: (any Error).self) { try mac.open(response, as: V2ActorAuthenticatedReply.self, reply: false, maximumBytes: 65_536) }
        let forbidden = try fixture.call(grant: grant, sequence: 2, principal: .service)
        await failure(.forbidden) { _ = try await fixture.auth.accept(mac.seal(forbidden, reply: false, maximumBytes: 65_536)) }
        clock.advance(.milliseconds(1_001))
        await failure(.sessionExpired) { _ = try await fixture.auth.accept(mac.seal(fixture.call(grant: grant, sequence: 3), reply: false, maximumBytes: 65_536)) }
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
             workerPermissions: Set<V2ActorServicePermission> = [.trustedSafety],
             clientHostedIDs: Set<V2ActorHostID> = [],
             clientPermissions: Set<V2ActorServicePermission> = [.userRoomCalls],
             gatewayNodeIDs: Set<String> = []) throws {
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
                .init(serviceID: client.serviceID, publicKey: clientKey.publicKey.rawRepresentation, permissions: clientPermissions, hostedIDs: clientHostedIDs, gatewayNodeIDs: gatewayNodeIDs),
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
                  request: .invoke(token: token, request: try request ?? .messaging(.sendOperation(try .init(command: try .init(
                    roomID: token.roomID, senderUserID: user, clientMessageID: ClientMessageID(uuid: UUID()),
                    text: "signed", media: [], mentions: [], entities: [], replyTo: nil, limits: .init(maxUTF8Bytes: 65_536)), firstSubmissionDeadlineMilliseconds: 1_900_000_000_000)))))
        }
    }

    private final class TestClock: Sendable {
        private let value = Mutex(ContinuousClock.now)
        var now: ContinuousClock.Instant { value.withLock { $0 } }
        func advance(_ duration: Duration) { value.withLock { $0 += duration } }
    }
}
