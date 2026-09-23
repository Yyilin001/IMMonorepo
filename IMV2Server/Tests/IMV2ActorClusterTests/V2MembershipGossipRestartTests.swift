import Testing
@testable import DistributedCluster

@Suite("Membership gossip after a node incarnation is replaced")
struct V2MembershipGossipRestartTests {
    @Test("three-member gossip omits a retired incarnation and accepts its legacy seen row")
    func retiredSeenRow() async throws {
        let system = await ClusterSystem("gossip-restart-test", settings: settings())
        defer { try? system.shutdown().wait() }

        let caller = node(port: 39001, id: 11)
        let oldHost = node(port: 39002, id: 12)
        let newHost = node(port: 39002, id: 13)
        let peer = node(port: 39003, id: 14)
        #expect(oldHost.endpoint == newHost.endpoint)
        #expect(oldHost != newHost)

        var gossip = Cluster.MembershipGossip(ownerNode: caller)
        gossip.membership = .init(members: [
            .init(node: caller, status: .up),
            .init(node: newHost, status: .joining),
            .init(node: peer, status: .up),
        ])
        let ownerVersion = VersionVector([
            (replicaID: .node(caller), version: 5),
            (replicaID: .node(newHost), version: 2),
            (replicaID: .node(peer), version: 3),
        ])
        let newHostVersion = VersionVector((replicaID: .node(newHost), version: 2))
        let peerVersion = VersionVector((replicaID: .node(peer), version: 3))
        gossip.seen.underlying = [
            caller: ownerVersion,
            newHost: newHostVersion,
            peer: peerVersion,
            oldHost: VersionVector((replicaID: .node(oldHost), version: 9)),
        ]

        let context = system.serialization.context
        let encoded = try gossip.toProto(context: context)
        #expect(Set(encoded.seenTable.rows.map(\.nodeID)) == [caller.nid.value, newHost.nid.value, peer.nid.value])

        // Simulate a sender running the earlier encoder, which included the
        // retired row even though the membership had already replaced it.
        var legacy = encoded
        var retiredRow = try #require(legacy.seenTable.rows.first { $0.nodeID == peer.nid.value })
        retiredRow.nodeID = oldHost.nid.value
        legacy.seenTable.rows.append(retiredRow)
        let decoded = try Cluster.MembershipGossip(fromProto: legacy, context: context)
        #expect(decoded.owner == caller)
        #expect(decoded.seen.underlying[oldHost] == nil)
        #expect(decoded.seen.underlying[caller] == ownerVersion)
        #expect(decoded.seen.underlying[newHost] == newHostVersion)
        #expect(decoded.seen.underlying[peer] == peerVersion)
        #expect(decoded.version == ownerVersion)

        var invalidOwner = legacy
        invalidOwner.ownerClusterNodeID = oldHost.nid.value
        #expect(throws: SerializationError.self) {
            _ = try Cluster.MembershipGossip(fromProto: invalidOwner, context: context)
        }

        var missingOwnerRow = legacy
        missingOwnerRow.seenTable.rows.removeAll { $0.nodeID == caller.nid.value }
        #expect(throws: SerializationError.self) {
            _ = try Cluster.MembershipGossip(fromProto: missingOwnerRow, context: context)
        }

        var missingOwnerMembership = gossip
        missingOwnerMembership.membership = .init(members: [
            .init(node: newHost, status: .joining),
            .init(node: peer, status: .up),
        ])
        #expect(throws: SerializationError.self) {
            _ = try missingOwnerMembership.toProto(context: context)
        }
        var missingOwnerSeenRow = gossip
        missingOwnerSeenRow.seen.underlying.removeValue(forKey: caller)
        #expect(throws: SerializationError.self) {
            _ = try missingOwnerSeenRow.toProto(context: context)
        }
    }

    private func settings() -> ClusterSystemSettings {
        var settings = ClusterSystemSettings(name: "gossip-restart-test", host: "127.0.0.1",
                                             port: Int.random(in: 30_000...60_000))
        settings.threadPoolSize = 1
        settings.downingStrategy = .none
        settings.onDownAction = .none
        return settings
    }

    private func node(port: Int, id: UInt64) -> Cluster.Node {
        .init(systemName: "gossip-restart-test", host: "127.0.0.1", port: port, nid: .init(id))
    }
}
