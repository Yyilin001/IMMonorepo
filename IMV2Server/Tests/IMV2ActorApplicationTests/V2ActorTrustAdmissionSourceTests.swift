import Crypto
import Foundation
import IMV2ActorCluster
import IMV2ActorContracts
import Testing
@testable import IMV2ActorApplication

@Suite("Signed trust authorization directory lifecycle")
struct V2ActorTrustAdmissionSourceTests {
    @Test("Generated admission directories enable ingestion for every process role",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_TEST_GENERATED_ADMISSION_DIRECTORIES"] == "1"))
    func generatedDirectories() async throws {
        let root = try #require(ProcessInfo.processInfo.environment["IMV2_ROOM_ACTOR_TEST_DEPLOYMENT_DIRECTORY"])
        for name in ["gateway", "account", "control-a", "control-b", "control-c"] {
            let bytes = try Data(contentsOf: URL(fileURLWithPath: root + "/" + name + "/configuration.json"))
            let document = try JSONDecoder().decode(V2RoomActorApplicationConfiguration.Document.self, from: bytes)
            let configuration = try V2RoomActorApplicationConfiguration(document: document, hostsRooms: nil,
                configuredShardIDs: ["rooms-primary"])
            let directory = try #require(configuration.trustAdmissionDirectory)
            let source = try V2ActorTrustAdmissionSource(directory: directory, trust: configuration.trust)
            do {
                try await source.start()
                #expect(try await source.stop(deadline: .now + .seconds(2)))
            } catch { _ = try? await source.stop(deadline: .now + .seconds(2)); throw error }
        }
    }

    @Test("Deployment tool output is accepted by the running source and replayed after restart",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_TRUST_ADMISSION_GENERATED_PACKET"] != nil))
    func generatedToolPacket() async throws {
        let environment = ProcessInfo.processInfo.environment
        let root = try #require(environment["IMV2_ROOM_ACTOR_TEST_DEPLOYMENT_DIRECTORY"])
        let packetPath = try #require(environment["IMV2_TRUST_ADMISSION_GENERATED_PACKET"])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("generated-grant-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = try Data(contentsOf: URL(fileURLWithPath: root + "/gateway/configuration.json"))
        let document = try JSONDecoder().decode(V2RoomActorApplicationConfiguration.Document.self, from: bytes)
        let newID = try V2ActorServiceID("new-gateway")
        for replay in [false, true] {
            let configuration = try V2RoomActorApplicationConfiguration(document: document, hostsRooms: true,
                configuredShardIDs: ["rooms-primary"])
            #expect(throws: V2ActorAuthenticationError.unknownService) { try configuration.trust.configuredService(newID) }
            let source = try V2ActorTrustAdmissionSource(directory: directory.path, trust: configuration.trust)
            do {
                try await source.start()
                if !replay {
                    try Data(contentsOf: URL(fileURLWithPath: packetPath)).write(
                        to: directory.appendingPathComponent("new-gateway.pb"), options: .atomic)
                    try await source.refresh()
                }
                let admitted = try configuration.trust.configuredService(newID)
                #expect(admitted.permissions.contains(.placementWrite))
                #expect(admitted.sourceIDs == ["rooms-primary", "user:users-primary", "control"])
                #expect(admitted.gatewayNodeIDs == ["new-gateway"])
                #expect(try await source.stop(deadline: .now + .seconds(2)))
            } catch { _ = try? await source.stop(deadline: .now + .seconds(2)); throw error }
        }
    }

    private struct Fixture {
        let directory: URL
        let deployment = UUID()
        let signer: V2ActorSigningIdentity
        let authority: V2ActorTrustedService
        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("trust-admission-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let key = Curve25519.Signing.PrivateKey(), id = try V2ActorServiceID("authority")
            signer = try .init(serviceID: id, privateKey: key.rawRepresentation)
            authority = try .init(serviceID: id, publicKey: key.publicKey.rawRepresentation, permissions: [])
        }
        func trust() throws -> V2ActorTrustStore {
            try .init(services: [authority], admissionAuthority: .init(deploymentID: deployment, serviceID: signer.serviceID))
        }
        func write(_ name: String, deployment: UUID? = nil) throws -> V2ActorServiceID {
            let key = Curve25519.Signing.PrivateKey(), id = try V2ActorServiceID(name)
            let service = try V2ActorTrustedService(serviceID: id, publicKey: key.publicKey.rawRepresentation,
                permissions: [.userRoomCalls])
            let packet = try signer.sign(V2ActorTrustAdmission(deploymentID: deployment ?? self.deployment,
                services: [service]), maximumBytes: 262_144)
            try V2ActorProtobuf.encode(packet).write(to: directory.appendingPathComponent(name + ".pb"), options: .atomic)
            return id
        }
    }

    @Test func startupPeriodicAdmissionAndFreshProcessReplay() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let first = try fixture.write("first"), trust = try fixture.trust()
        let source = try V2ActorTrustAdmissionSource(directory: fixture.directory.path, trust: trust)
        do {
            try await source.start()
            #expect(try trust.configuredService(first).permissions == [.userRoomCalls])
            let second = try fixture.write("second")
            let deadline = ContinuousClock.now + .seconds(4)
            while (try? trust.configuredService(second)) == nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(try trust.configuredService(second).permissions == [.userRoomCalls])
            #expect(try await source.stop(deadline: .now + .seconds(2)))
            let restored = try fixture.trust()
            let restarted = try V2ActorTrustAdmissionSource(directory: fixture.directory.path, trust: restored)
            do {
                try await restarted.start()
                #expect(try restored.configuredService(first).permissions == [.userRoomCalls])
                #expect(try restored.configuredService(second).permissions == [.userRoomCalls])
                #expect(try await restarted.stop(deadline: .now + .seconds(2)))
            } catch { _ = try? await restarted.stop(deadline: .now + .seconds(2)); throw error }
        } catch { _ = try? await source.stop(deadline: .now + .seconds(2)); throw error }
    }

    @Test(arguments: ["wrong-deployment", "malformed", "symlink", "oversized"])
    func startupRejectsInvalidDocumentsAndClosesIO(kind: String) async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let path = fixture.directory.appendingPathComponent("invalid.pb")
        switch kind {
        case "wrong-deployment": _ = try fixture.write("invalid", deployment: UUID())
        case "symlink":
            let target = fixture.directory.appendingPathComponent("target.tmp")
            try Data([1]).write(to: target)
            try FileManager.default.createSymbolicLink(at: path, withDestinationURL: target)
        case "oversized": try Data(repeating: 0, count: 524_289).write(to: path)
        default: try Data([1]).write(to: path)
        }
        let trust = try fixture.trust(), source = try V2ActorTrustAdmissionSource(directory: fixture.directory.path, trust: trust)
        do { try await source.start(); Issue.record("Invalid trust source started") } catch {}
        #expect(try await source.stop(deadline: .now + .seconds(2)))
        #expect(throws: V2ActorAuthenticationError.unknownService) { try trust.configuredService(V2ActorServiceID("invalid")) }
    }

    @Test func changedFileIsReverifiedAndCannotRevokeAcceptedIdentity() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let id = try fixture.write("existing"), trust = try fixture.trust()
        let source = try V2ActorTrustAdmissionSource(directory: fixture.directory.path, trust: trust)
        do {
            try await source.start()
            let path = fixture.directory.appendingPathComponent("existing.pb")
            try Data([1]).write(to: path, options: .atomic)
            do { try await source.refresh(); Issue.record("Changed malformed file reused a cached authorization") } catch {}
            #expect(try trust.configuredService(id).permissions == [.userRoomCalls])
            try FileManager.default.removeItem(at: path)
            try await source.refresh()
            #expect(try trust.configuredService(id).permissions == [.userRoomCalls])
            #expect(try await source.stop(deadline: .now + .seconds(2)))
        } catch { _ = try? await source.stop(deadline: .now + .seconds(2)); throw error }
    }
}
