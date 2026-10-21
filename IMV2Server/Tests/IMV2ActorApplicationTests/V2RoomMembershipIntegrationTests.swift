import Foundation
import IMV2ActorCluster
import IMV2ActorContracts
import IMV2ServerContracts
import IMV2Core
import Testing
@testable import IMV2ActorApplication

@Suite("Running caller follows certified room membership", .serialized)
struct V2RoomMembershipIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMV2_ROOM_MEMBERSHIP_DEPLOYMENT"] != nil))
    func runningCallerAppliesJointFinalAndSuspendsWithoutQuorum() async throws {
        let root = try #require(ProcessInfo.processInfo.environment["IMV2_ROOM_MEMBERSHIP_DEPLOYMENT"])
        let files = FileManager.default.temporaryDirectory.appendingPathComponent("room-membership-" + UUID().uuidString)
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
        var services = try configs.map(V2PlacementControlService.init)
        let controller = try configuration("membership-controller")
        let account = try configuration("account")
        let a = try #require(controller.realtimePeers.first { $0.nodeID == "gateway" })
        let b = try #require(controller.realtimePeers.first { $0.nodeID == "new-gateway" })
        let ra = try #require(controller.discovery.peers.first { $0.serviceID.rawValue == "gateway" })
        let rb = try #require(controller.discovery.peers.first { $0.serviceID.rawValue == "new-gateway" })
        var caller: V2RoomActorApplication?
        var failure: (any Error)?
        do {
            for config in configs { try await V2PlacementControlService.provision(configuration: config) }
            try await withThrowingTaskGroup(of: Void.self) { group in
                for service in services { group.addTask { try await service.start() } }
                try await group.waitForAll()
            }
            // Missing authoritative membership must fail startup and release the
            // caller's listener, allowing a later start at the same endpoint.
            await #expect(throws: (any Error).self) {
                try await V2RoomActorApplication.start(configuration: account,
                    ownerRouter: UnusedMembershipRouter(), roomDatabases: [:])
            }
            let initialInspection = try await V2PlacementControlService.inspect(configuration: controller)
            var origin = try #require(initialInspection.first).revision
            func submit(_ record: V2ActorServiceMembershipRecord, origin: UInt64) async throws -> UInt64 {
                let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record))
                let proposal: [String: Any] = ["deploymentID": controller.placementControl.clusterID.uuidString,
                    "shardID": "rooms-primary", "requestID": UUID().uuidString, "originRevision": origin, "membership": encoded]
                let request = try JSONSerialization.data(withJSONObject: proposal)
                let first = try await V2PlacementControlService.installServiceMembership(configuration: controller, request: request)
                let retry = try await V2PlacementControlService.installServiceMembership(configuration: controller, request: request)
                #expect(first == retry)
                let receipt = try #require(JSONSerialization.jsonObject(with: first) as? [String: Any])
                return try #require(receipt["controlRevision"] as? NSNumber).uint64Value
            }
            origin = try await submit(.init(revision: 1, current: [a.nodeID], peers: [a], roomPeers: [ra]), origin: origin)
            let application = try await V2RoomActorApplication.start(configuration: account,
                ownerRouter: UnusedMembershipRouter(), roomDatabases: [:])
            caller = application
            let initial = await application.roomMembershipStatus()
            #expect(initial.revision == 1 && initial.confirmed && initial.configuredHosts == [ra.hostID])
            let observed = await application.roomRuntimeMetricsSnapshot().membership
            #expect(observed?.revision == 1 && observed?.confirmed == true && observed?.configuredHosts == 1)
            #expect(observed?.healthyHosts == 0 && observed?.realtimeRevision == nil && observed?.realtimeQualified == nil)
            // The static deployment contains both hosts. This proves startup did
            // not silently use its expanded peer list instead of committed state.
            #expect(account.discovery.peers.count == 2)
            func waitFor(_ revision: UInt64, hosts: Set<V2ActorHostID>, confirmed: Bool = true) async throws {
                let deadline = ContinuousClock.now + .seconds(35)
                while ContinuousClock.now < deadline {
                    let status = await application.roomMembershipStatus()
                    if status.revision == revision && status.confirmed == confirmed && status.configuredHosts == hosts { return }
                    try await Task.sleep(for: .milliseconds(25))
                }
                throw V2ActorPlacementError.unavailable
            }
            origin = try await submit(.init(revision: 2, current: [a.nodeID], next: [b.nodeID],
                peers: [a,b], roomPeers: [ra,rb]), origin: origin)
            try await waitFor(2, hosts: [ra.hostID, rb.hostID])
            origin = try await submit(.init(revision: 3, current: [b.nodeID], peers: [b], roomPeers: [rb]), origin: origin)
            try await waitFor(3, hosts: [rb.hostID])
            #expect(origin > initialInspection[0].revision)
            // Lose two real voters. Gossip or cached placement state must not
            // keep a caller ready when the room roster is no longer confirmed.
            for index in [0,1] { #expect(try await services[index].stop(deadline: .now + .seconds(10))) }
            try await waitFor(3, hosts: [rb.hostID], confirmed: false)
            #expect(await application.readiness() == false)
            #expect(await application.roomRuntimeMetricsSnapshot().membership?.confirmed == false)
            for index in [0,1] {
                // A real restarted process decodes configuration again and gets
                // a new incarnation; reusing the old one is an invalid identity.
                let restarted = try configuration(["control-a", "control-b"][index], storage: true)
                #expect(restarted.placementControl.identity != configs[index].placementControl.identity)
                services[index] = try V2PlacementControlService(configuration: restarted)
            }
            try await withThrowingTaskGroup(of: Void.self) { group in
                for index in [0,1] { let service = services[index]; group.addTask { try await service.start() } }
                try await group.waitForAll()
            }
            try await waitFor(3, hosts: [rb.hostID])
            #expect(try await application.stop(deadline: .now + .seconds(15)))
            caller = nil
            // New process also sees final state from durable control storage.
            let restarted = try await V2RoomActorApplication.start(configuration: configuration("account"),
                ownerRouter: UnusedMembershipRouter(), roomDatabases: [:])
            caller = restarted
            let restored = await restarted.roomMembershipStatus()
            #expect(restored.revision == 3 && restored.confirmed && restored.configuredHosts == [rb.hostID])
        } catch { failure = error }
        if let caller { #expect(try await caller.stop(deadline: .now + .seconds(15))) }
        for service in services { #expect(try await service.stop(deadline: .now + .seconds(10))) }
        if let failure { throw failure }
    }
}
private struct UnusedMembershipRouter: V2RoomShardRouting {
    func route(for roomID: RoomID) async throws -> V2RoomShardRoute { throw V2RoomActorApplicationError.invalidRole }
}
