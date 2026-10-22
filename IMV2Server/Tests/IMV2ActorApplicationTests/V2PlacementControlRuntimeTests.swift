import Foundation
import Crypto
import IMV2ActorCluster
import IMV2ActorContracts
import IMV2ActorRuntime
import IMV2Server
import IMV2ServerContracts
import IMV2Core
import Testing
@testable import IMV2ActorApplication

@Suite("Production control composition on real disk and mTLS", .serialized)
struct V2PlacementControlRuntimeTests {
    @Test("Dedicated exclusion caller needs no realtime role; ordinary callers cannot use that exception",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_ROOM_ACTOR_EXCLUSION_CONFIGURATION_FILE"] != nil))
    func exclusionCallerConfiguration() throws {
        let path = try #require(ProcessInfo.processInfo.environment["IMV2_ROOM_ACTOR_EXCLUSION_CONFIGURATION_FILE"])
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        func build(_ value: [String: Any]) throws -> V2RoomActorApplicationConfiguration {
            let document = try JSONDecoder().decode(V2RoomActorApplicationConfiguration.Document.self,
                from: JSONSerialization.data(withJSONObject: value))
            return try .init(document: document, hostsRooms: false, configuredShardIDs: ["rooms-primary"])
        }
        let configuration = try build(object)
        #expect(configuration.hostIdentity == nil && configuration.placementControl.identity == nil)
        #expect(configuration.policyPlacement == nil)
        #expect(!configuration.realtimePeers.contains { $0.serviceID == configuration.signer.serviceID.rawValue })
        var services = try #require(object["services"] as? [[String: Any]])
        let index = try #require(services.firstIndex { $0["id"] as? String == object["serviceID"] as? String })
        services[index]["permissions"] = ["placementRead", "placementWrite"]
        object["services"] = services
        #expect(throws: V2RoomActorApplicationConfigurationError.invalidConfiguration) { try build(object) }
    }

    @Test("Independent voters stay alive through room registration, native drain and retirement",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_ROOM_ACTOR_TEST_DEPLOYMENT_DIRECTORY"] != nil))
    func nativeProductionLifecycle() async throws {
        let root = try #require(ProcessInfo.processInfo.environment["IMV2_ROOM_ACTOR_TEST_DEPLOYMENT_DIRECTORY"])
        let files = FileManager.default.temporaryDirectory.appendingPathComponent("production-placement-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: files) }
        let authorizations = files.appendingPathComponent("authorizations")
        try FileManager.default.createDirectory(at: authorizations, withIntermediateDirectories: false)
        let authorityKey = Curve25519.Signing.PrivateKey()
        let authorityID = try V2ActorServiceID("trust-admission-root")
        let authoritySigner = try V2ActorSigningIdentity(serviceID: authorityID, privateKey: authorityKey.rawRepresentation)
        func configuration(_ name: String, storage: Bool = false) throws -> V2RoomActorApplicationConfiguration {
            var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf:
                URL(fileURLWithPath: root + "/" + name + "/configuration.json"))) as? [String: Any])
            var trusted = try #require(object["services"] as? [[String: Any]])
            trusted.append(["id": authorityID.rawValue, "publicKeyBase64": authorityKey.publicKey.rawRepresentation.base64EncodedString(),
                            "permissions": [], "hostIDs": [], "gatewayNodeIDs": [], "shardIDs": ["rooms-primary"]])
            object["services"] = trusted
            object["trustAdmissionAuthorityServiceID"] = authorityID.rawValue
            object["trustAdmissionDirectory"] = authorizations.path
            if storage {
                var control = try #require(object["placementControl"] as? [String: Any])
                control["storagePaths"] = ["rooms-primary": files.appendingPathComponent(name + ".pb").path]
                object["placementControl"] = control
            }
            let document = try JSONDecoder().decode(V2RoomActorApplicationConfiguration.Document.self,
                from: JSONSerialization.data(withJSONObject: object))
            return try .init(document: document, hostsRooms: nil, configuredShardIDs: ["rooms-primary"])
        }
        let configs = try ["control-a", "control-b", "control-c"].map { try configuration($0, storage: true) }
        let services = try configs.map(V2PlacementControlService.init)
        var gateway: V2PlacementControlRuntime?
        var caller: V2RoomActorApplication?
        var host: V2RoomActivationHost<Int, Int>?
        var failure: (any Error)?
        do {
            for config in configs { try await V2PlacementControlService.provision(configuration: config) }
            try await withThrowingTaskGroup(of: Void.self) { group in
                for service in services { group.addTask { try await service.start() } }
                try await group.waitForAll()
            }
            let newcomerKey = Curve25519.Signing.PrivateKey(), newcomerID = try V2ActorServiceID("admitted-at-runtime")
            let newcomer = try V2ActorTrustedService(serviceID: newcomerID,
                publicKey: newcomerKey.publicKey.rawRepresentation, permissions: [.userRoomCalls])
            let authorization = V2ActorTrustAdmission(deploymentID: configs[0].placementControl.clusterID, services: [newcomer])
            let packet = try authoritySigner.sign(authorization, maximumBytes: 262_144)
            try V2ActorProtobuf.encode(packet).write(to: authorizations.appendingPathComponent("new-service.pb"), options: .atomic)
            let admissionDeadline = ContinuousClock.now + .seconds(4)
            while !configs.allSatisfy({ (try? $0.trust.configuredService(newcomerID)) != nil }), ContinuousClock.now < admissionDeadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(configs.allSatisfy { (try? $0.trust.configuredService(newcomerID)) != nil })
            let config = try configuration("gateway"), identity = try #require(config.hostIdentity)
            let runtime = V2PlacementControlRuntime(configuration: config); gateway = runtime
            let placement = try await runtime.start()
            #expect(try config.trust.configuredService(newcomerID).permissions == [.userRoomCalls])
            try await placement.register(identity, shards: ["rooms-primary"])
            let room = RoomID(uuid: UUID()), owner = try V2RoomDataOwner(shardID: "rooms-primary", epoch: 0)
            #expect(try placement.grant(roomID: room, owner: owner).host == identity)
            let budget = V2RoomCommandBudget(configuration: config.runtime)
            let native = V2RoomActivationHost<Int, Int>(identity: identity, placement: placement,
                configuration: config.runtime, budget: budget, classify: { _ in .barrier },
                factory: .init(pureRoomLogPull: { _, _, _ in .rolledBack(.invalidRequest) }) { _ in
                    .init(restore: { _ in }, execute: { .committed($0.items.map(\.request)) },
                          invalidateReservation: { _ in }, close: {})
                })
            host = native; await native.start()
            guard case .ready(let token) = try await native.activate(roomID: room, owner: owner, deadline: .now + .seconds(3)) else {
                throw V2RoomCallFailure.notAccepted(.notReady)
            }
            #expect(try await native.invoke(token: token, request: 73, deadline: .now + .seconds(3)) == 73)
            let account = try configuration("account")
            let application = try await V2RoomActorApplication.start(configuration: account,
                ownerRouter: UnusedControlTestRouter(), roomDatabases: [:])
            caller = application
            let readyDeadline = ContinuousClock.now + .seconds(5)
            while !(await application.readiness()), ContinuousClock.now < readyDeadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(await application.readiness())
            let proof = try #require(await native.stop(deadline: .now + .seconds(3)).proof)
            host = nil
            try await placement.retireAfterDrain(proof, shards: ["rooms-primary"])
            #expect(throws: V2RoomCallFailure.notAccepted(.unavailable)) { try placement.grant(roomID: room, owner: owner) }
            #expect(try await application.stop(deadline: .now + .seconds(5)))
            caller = nil
            let retiredInspection = try await V2PlacementControlService.inspect(configuration: account)
            let retiredShard = try #require(retiredInspection.first { $0.shardID == "rooms-primary" })
            #expect(retiredShard.archive.receipts > 0 && retiredShard.archive.bytes > 0)
            #expect(retiredShard.archive.availableReceipts == retiredShard.archive.maximumReceipts
                - retiredShard.archive.receipts - retiredShard.archive.reservedReceipts)
            #expect(retiredShard.archive.availableBytes == retiredShard.archive.maximumBytes
                - retiredShard.archive.bytes - retiredShard.archive.reservedBytes)
            #expect(retiredShard.hosts.contains {
                $0.identity.hostID == identity.hostID.rawValue &&
                $0.identity.incarnationID == identity.incarnationID && $0.retired
            })
            // Inspection must reject a voting/hosting configuration before
            // opening its already-live storage or network listener.
            await #expect(throws: V2RoomActorApplicationError.invalidRole) {
                try await V2PlacementControlService.inspect(configuration: config)
            }
            await #expect(throws: V2RoomActorApplicationError.invalidRole) {
                try await V2PlacementControlService.inspect(configuration: configs[0])
            }
            // Supervisor TERM arrives through cancellation of its owning task.
            // A live trust-directory worker must still drain before the same
            // listener and placement identity can be reused below.
            let cancelledShutdown = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                #expect(Task.isCancelled)
                return try await runtime.stop(deadline: .now + .seconds(5))
            }
            #expect(try await cancelledShutdown.value)
            gateway = nil
            // Retirement did not stop any of the independent voters. A new
            // exact process incarnation can register using the same history.
            let restartedConfig = try configuration("gateway"), restartedIdentity = try #require(restartedConfig.hostIdentity)
            let restarted = V2PlacementControlRuntime(configuration: restartedConfig); gateway = restarted
            let next = try await restarted.start()
            try await next.register(restartedIdentity, shards: ["rooms-primary"])
            #expect(try next.grant(roomID: room, owner: owner).host == restartedIdentity)
            let activeInspection = try await V2PlacementControlService.inspect(configuration: account)
            let activeShard = try #require(activeInspection.first { $0.shardID == "rooms-primary" })
            #expect(activeShard.revision > retiredShard.revision)
            #expect(activeShard.hosts.contains {
                $0.identity.hostID == restartedIdentity.hostID.rawValue &&
                $0.identity.incarnationID == restartedIdentity.incarnationID && !$0.retired
            })
            #expect(activeShard.partitions.allSatisfy {
                $0.owner.incarnationID == restartedIdentity.incarnationID && !$0.retired && $0.transfer == nil
            })
        } catch { failure = error }
        if let host { _ = await host.stop(deadline: .now + .seconds(5)) }
        if let caller { #expect(try await caller.stop(deadline: .now + .seconds(5))) }
        if let gateway { #expect(try await gateway.stop(deadline: .now + .seconds(5))) }
        for service in services { #expect(try await service.stop(deadline: .now + .seconds(5))) }
        if let failure { throw failure }
    }
}
private struct UnusedControlTestRouter: V2RoomShardRouting {
    func route(for roomID: RoomID) async throws -> V2RoomShardRoute { throw V2RoomActorApplicationError.invalidRole }
}
