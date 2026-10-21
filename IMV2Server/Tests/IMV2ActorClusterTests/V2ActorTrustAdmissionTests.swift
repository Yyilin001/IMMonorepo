import Crypto
import Foundation
import IMV2ActorContracts
import Testing
@testable import IMV2ActorCluster

@Suite("Deployment-pinned signed service admission")
struct V2ActorTrustAdmissionTests {
    @Test func signedScopesDoNotOverrideLocalRestrictionsOrGrantExtraRoles() throws {
        let fixture = try Fixture()
        let key = Curve25519.Signing.PrivateKey(), id = try V2ActorServiceID("scoped-newcomer")
        let service = try V2ActorTrustedService(serviceID: id, publicKey: key.publicKey.rawRepresentation,
            permissions: [.placementRead], sourceIDs: ["room-a", "room-b"])
        #expect(fixture.trust.authorizedSources(for: id, configured: nil).isEmpty)
        try fixture.trust.admitAuthorizedServices(fixture.packet([service]))
        #expect(fixture.trust.authorizedSources(for: id, configured: nil, requiring: [.placementRead]) == ["room-a", "room-b"])
        #expect(fixture.trust.authorizedSources(for: id, configured: nil, requiring: [.placementWrite]).isEmpty)
        #expect(fixture.trust.authorizedSources(for: id, configured: ["room-a"]) == ["room-a"])
        #expect(fixture.trust.authorizedSources(for: id, configured: []).isEmpty)
        let changed = try V2ActorTrustedService(serviceID: id, publicKey: key.publicKey.rawRepresentation,
            permissions: [.placementRead], sourceIDs: ["room-c"])
        #expect(throws: V2ActorAuthenticationError.forbidden) {
            try fixture.trust.admitAuthorizedServices(fixture.packet([changed]))
        }
        let bootstrap = try V2ActorTrustStore(services: [service])
        #expect(bootstrap.authorizedSources(for: id, configured: nil).isEmpty)
    }

    private struct Identity {
        let signer: V2ActorSigningIdentity
        let trusted: V2ActorTrustedService
        init(_ name: String, permissions: Set<V2ActorServicePermission> = [],
             hosts: Set<V2ActorHostID> = [], gateways: Set<String> = []) throws {
            let key = Curve25519.Signing.PrivateKey(), id = try V2ActorServiceID(name)
            signer = try .init(serviceID: id, privateKey: key.rawRepresentation)
            trusted = try .init(serviceID: id, publicKey: key.publicKey.rawRepresentation,
                permissions: permissions, hostedIDs: hosts, gatewayNodeIDs: gateways)
        }
    }
    private struct Fixture {
        let deployment = UUID()
        let authority: Identity
        let existing: Identity
        let trust: V2ActorTrustStore
        init() throws {
            authority = try Identity("membership-authority")
            existing = try Identity("existing", permissions: [.userRoomCalls])
            trust = try .init(services: [authority.trusted, existing.trusted],
                admissionAuthority: .init(deploymentID: deployment, serviceID: authority.signer.serviceID))
        }
        func packet(_ services: [V2ActorTrustedService], deployment: UUID? = nil) throws -> V2ActorSignedPacket {
            try authority.signer.sign(V2ActorTrustAdmission(deploymentID: deployment ?? self.deployment,
                services: services), maximumBytes: 262_144)
        }
    }

    @Test func existingAuthenticatorSeesAuthorizedNewIdentityWithoutRestart() throws {
        let fixture = try Fixture(), copy = fixture.trust
        let host = V2ActorHostIdentity(hostID: .init(uuid: UUID()), incarnationID: UUID())
        let authenticator = V2ActorSessionAuthenticator(host: host, trust: copy, limits: try .init())
        let newcomer = try Identity("newcomer", permissions: [.userRoomCalls])
        let hello = V2ActorSessionHello(serviceID: newcomer.signer.serviceID, callerIncarnation: UUID(),
            recipient: host, handshakeID: UUID())
        let packet = try newcomer.signer.sign(hello, maximumBytes: 16_384)
        #expect(throws: V2ActorAuthenticationError.unknownService) { try authenticator.openSession(packet) }
        try fixture.trust.admitAuthorizedServices(fixture.packet([newcomer.trusted]))
        let grant = try authenticator.openSession(packet)
        #expect(grant.serviceID == newcomer.signer.serviceID)
        #expect(try copy.configuredService(newcomer.signer.serviceID).permissions == [.userRoomCalls])
        let authorityHello = V2ActorSessionHello(serviceID: fixture.authority.signer.serviceID,
            callerIncarnation: UUID(), recipient: host, handshakeID: UUID())
        #expect(throws: V2ActorAuthenticationError.forbidden) {
            try authenticator.openSession(fixture.authority.signer.sign(authorityHello, maximumBytes: 16_384))
        }
    }

    @Test func ordinaryServicesAndOtherDeploymentsCannotGrantTrust() throws {
        let fixture = try Fixture(), newcomer = try Identity("newcomer", permissions: [.userRoomCalls])
        let document = V2ActorTrustAdmission(deploymentID: fixture.deployment, services: [newcomer.trusted])
        #expect(throws: V2ActorAuthenticationError.forbidden) {
            try fixture.trust.admitAuthorizedServices(fixture.existing.signer.sign(document, maximumBytes: 262_144))
        }
        #expect(throws: V2ActorAuthenticationError.invalidRequest) {
            try fixture.trust.admitAuthorizedServices(fixture.packet([newcomer.trusted], deployment: UUID()))
        }
        let impostor = try Identity("membership-authority")
        #expect(throws: V2ActorAuthenticationError.invalidSignature) {
            try fixture.trust.admitAuthorizedServices(impostor.signer.sign(document, maximumBytes: 262_144))
        }
        #expect(throws: V2ActorAuthenticationError.unknownService) { try fixture.trust.configuredService(newcomer.signer.serviceID) }
    }

    @Test func batchValidationIsAtomicAndCannotStealHostOrGateway() throws {
        let fixture = try Fixture(), host = V2ActorHostID(uuid: UUID())
        let first = try Identity("first", permissions: [.realtimeReceive], hosts: [host], gateways: ["node"])
        try fixture.trust.admitAuthorizedServices(fixture.packet([first.trusted]))
        let valid = try Identity("valid", permissions: [.userRoomCalls])
        let collision = try Identity("collision", permissions: [.realtimeReceive], hosts: [host])
        #expect(throws: V2ActorAuthenticationError.invalidConfiguration) {
            try fixture.trust.admitAuthorizedServices(fixture.packet([valid.trusted, collision.trusted]))
        }
        #expect(throws: V2ActorAuthenticationError.unknownService) { try fixture.trust.configuredService(valid.signer.serviceID) }
        let gatewayCollision = try Identity("gateway-collision", permissions: [.realtimeReceive], gateways: ["node"])
        #expect(throws: V2ActorAuthenticationError.invalidConfiguration) {
            try fixture.trust.admitAuthorizedServices(fixture.packet([gatewayCollision.trusted]))
        }
        #expect(try fixture.trust.configuredHostServiceID(for: host) == first.signer.serviceID)
    }

    @Test func existingKeysAndPermissionsAreImmutable() throws {
        let fixture = try Fixture(), old = fixture.existing.trusted
        let replacement = try Identity("existing", permissions: [.userRoomCalls])
        let escalated = try V2ActorTrustedService(serviceID: old.serviceID,
            publicKey: old.publicKey.rawRepresentation, permissions: [.placementVote])
        for change in [replacement.trusted, escalated] {
            #expect(throws: V2ActorAuthenticationError.forbidden) {
                try fixture.trust.admitAuthorizedServices(fixture.packet([change]))
            }
        }
        #expect(try fixture.trust.configuredService(old.serviceID).permissions == old.permissions)
    }

    @Test func concurrentExactReplaysShareOneTrustStore() async throws {
        let fixture = try Fixture(), newcomer = try Identity("newcomer", permissions: [.userRoomCalls])
        let packet = try fixture.packet([newcomer.trusted]), trust = fixture.trust
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<32 { group.addTask { try trust.admitAuthorizedServices(packet) } }
            try await group.waitForAll()
        }
        #expect(try fixture.trust.configuredService(newcomer.signer.serviceID).permissions == [.userRoomCalls])
    }

    @Test func bootstrapMustExplicitlyPinDedicatedAuthority() throws {
        let fixture = try Fixture()
        let disabled = try V2ActorTrustStore(services: [fixture.authority.trusted, fixture.existing.trusted])
        #expect(throws: V2ActorAuthenticationError.forbidden) {
            try disabled.admitAuthorizedServices(fixture.packet([fixture.existing.trusted]))
        }
        #expect(throws: V2ActorAuthenticationError.invalidConfiguration) {
            try V2ActorTrustStore(services: [fixture.existing.trusted],
                admissionAuthority: .init(deploymentID: fixture.deployment, serviceID: fixture.existing.signer.serviceID))
        }
        #expect(throws: V2ActorAuthenticationError.invalidRequest) {
            try fixture.trust.admitAuthorizedServices(fixture.packet([]))
        }
    }
}
