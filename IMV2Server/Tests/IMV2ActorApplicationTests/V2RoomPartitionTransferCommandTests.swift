import Foundation
import IMV2ActorCluster
import IMV2ActorContracts
import IMV2ActorRuntime
import IMV2Core
import Testing
@testable import IMV2ActorApplication

@Suite("Operator partition transfer over real control and room transports", .serialized)
struct V2RoomPartitionTransferCommandTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMV2_TRANSFER_DEPLOYMENT"] != nil))
    func authenticatesDrainsAndReplays() async throws {
        let root = try #require(ProcessInfo.processInfo.environment["IMV2_TRANSFER_DEPLOYMENT"])
        let files = FileManager.default.temporaryDirectory.appendingPathComponent("transfer-command-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: files) }
        func configuration(_ name: String, storage: Bool = false) throws -> V2RoomActorApplicationConfiguration {
            var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf:
                URL(fileURLWithPath: root + "/" + name + "/configuration.json"))) as? [String: Any])
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
        let controller = try configuration("placement-controller")
        let membershipController = try configuration("membership-controller")
        #expect(controller.allowedShards.isEmpty)
        #expect(controller.transferShardIDs == ["rooms-primary"])
        #expect(try configuration("account").transferShardIDs.isEmpty)
        #expect(membershipController.transferShardIDs.isEmpty)
        var runtimes: [V2PlacementControlRuntime] = []
        var nodes: [(V2RoomClusterNode, V2RoomActorPlacementRuntime)] = []
        var hosts: [V2RoomActivationHost<V2RoomRequest, V2RoomResponse>] = []
        var identities: [V2ActorHostIdentity] = []
        let closes = TransferCloseCounter()
        var failure: (any Error)?
        do {
            for config in configs { try await V2PlacementControlService.provision(configuration: config) }
            try await withThrowingTaskGroup(of: Void.self) { group in
                for service in services { group.addTask { try await service.start() } }
                try await group.waitForAll()
            }
            let inspection = try await V2PlacementControlService.inspect(configuration: controller)
            let membership = try V2ActorServiceMembershipRecord(revision: 1,
                current: controller.realtimePeers.map(\.nodeID), peers: controller.realtimePeers,
                roomPeers: controller.discovery.peers)
            let proposal: [String: Any] = ["deploymentID": controller.placementControl.clusterID.uuidString,
                "shardID": "rooms-primary", "requestID": UUID().uuidString, "originRevision": inspection[0].revision,
                "membership": try JSONSerialization.jsonObject(with: JSONEncoder().encode(membership))]
            _ = try await V2PlacementControlService.installServiceMembership(configuration: membershipController,
                request: JSONSerialization.data(withJSONObject: proposal))
            for name in ["gateway", "new-gateway"] {
                let config = try configuration(name), identity = try #require(config.hostIdentity)
                let runtime = V2PlacementControlRuntime(configuration: config); runtimes.append(runtime)
                let placement = try await runtime.start()
                try await placement.register(identity, shards: ["rooms-primary"])
                let host = V2RoomActivationHost<V2RoomRequest, V2RoomResponse>(identity: identity,
                    placement: placement, configuration: config.runtime, budget: .init(configuration: config.runtime),
                    classify: { _ in .barrier }, factory: .init { _ in
                        .init(restore: { _ in }, execute: { turn in
                            .committed(turn.items.map { _ in .recovery(.failure(.invalidRequest)) })
                        }, invalidateReservation: { _ in }, close: { await closes.record() })
                    })
                let node = V2RoomClusterNode(configuration: try .init(name: config.name,
                    host: config.address, port: config.port, tls: config.tls, threadPoolSize: 1,
                    allowedShards: config.allowedShards, serviceShardAccess: config.serviceShardAccess),
                    identity: identity, host: host, signer: config.signer, trust: config.trust,
                    authenticationLimits: config.authentication, runtimeConfiguration: config.runtime,
                    placementDrain: placement.drainageService(host: host))
                nodes.append((node, placement)); hosts.append(host); identities.append(identity)
                _ = try await node.start()
            }
            let owner = try V2RoomDataOwner(shardID: "rooms-primary", epoch: 0)
            var room = RoomID(uuid: UUID())
            for _ in 0..<1000 {
                if (try? nodes[0].1.grant(roomID: room, owner: owner).host) == identities[0] { break }
                room = RoomID(uuid: UUID())
            }
            let grant = try nodes[0].1.grant(roomID: room, owner: owner)
            #expect(grant.host == identities[0])
            guard case .ready = try await hosts[0].activate(roomID: room, owner: owner, deadline: .now + .seconds(3)) else {
                throw V2RoomCallFailure.notAccepted(.notReady)
            }
            #expect(await hosts[0].snapshot().activeRooms == 1)
            let shape = try V2RoomActorPlacementRuntime.initialSnapshot(deploymentID: controller.placementControl.clusterID,
                shard: "rooms-primary", peers: controller.discovery.peers)
            let partition = shape.partition(for: room)
            let before = try await V2PlacementControlService.inspect(configuration: controller)[0]
            let command = V2RoomPartitionTransferCommand(deploymentID: controller.placementControl.clusterID,
                shardID: "rooms-primary", partition: partition, expectedHost: identities[0], expectedEpoch: grant.epoch,
                successor: identities[1], transferID: UUID(), originRevision: before.revision)
            try command.validate(configuration: controller)
            #expect(throws: V2RoomActorApplicationError.invalidRole) { try command.validate(configuration: membershipController) }
            #expect(throws: V2RoomActorApplicationError.invalidRole) { try command.validate(configuration: configuration("account")) }
            let fields = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(command)) as? [String: Any])
            let invalid: [(String, Any)] = [("deploymentID", UUID().uuidString), ("shardID", "other"),
                ("originRevision", 0), ("expectedEpoch", 0), ("partition", -1), ("partition", 4096),
                ("successor", try JSONSerialization.jsonObject(with: JSONEncoder().encode(identities[0])))]
            for (key, value) in invalid {
                var altered = fields; altered[key] = value
                let request = try JSONDecoder().decode(V2RoomPartitionTransferCommand.self,
                    from: JSONSerialization.data(withJSONObject: altered))
                #expect(throws: V2RoomActorApplicationError.invalidRole) { try request.validate(configuration: controller) }
            }
            let request = try JSONEncoder().encode(command)
            let first = try await V2PlacementControlService.transferRoomPartition(configuration: controller, request: request)
            #expect(await hosts[0].snapshot().activeRooms == 0)
            #expect(await closes.count == 1)
            let after = try await V2PlacementControlService.inspect(configuration: controller)[0]
            let moved = try #require(after.partitions.first { $0.partition == partition })
            #expect(moved.owner.hostID == identities[1].hostID.rawValue && moved.epoch == grant.epoch + 1 && moved.transfer == nil)
            let retry = try await V2PlacementControlService.transferRoomPartition(configuration: controller, request: request)
            #expect(first == retry)
            #expect(await closes.count == 1)
            try await nodes[1].1.refresh()
            guard case .ready = try await hosts[1].activate(roomID: room, owner: owner, deadline: .now + .seconds(3)) else {
                throw V2RoomCallFailure.notAccepted(.notReady)
            }
            #expect(await hosts[1].snapshot().activeRooms == 1)
        } catch { failure = error }
        for (node, placement) in nodes {
            let result = try await node.stop(deadline: .now + .seconds(10))
            if let proof = result.proof { try await placement.retireAfterDrain(proof, shards: ["rooms-primary"]) }
            #expect(result.completed)
        }
        for runtime in runtimes { #expect(try await runtime.stop(deadline: .now + .seconds(10))) }
        for service in services { #expect(try await service.stop(deadline: .now + .seconds(10))) }
        if let failure { throw failure }
    }
}
private actor TransferCloseCounter {
    var count = 0
    func record() { count += 1 }
}
