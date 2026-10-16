import Testing
@testable import DistributedCluster

@Suite("Receptionist shutdown")
struct V2ReceptionistShutdownTests {
    @Test("Late member removal does not resolve an actor after system shutdown")
    func lateMemberRemoval() async throws {
        var settings = ClusterSystemSettings(name: "receptionist-shutdown")
        settings.disable()
        settings.threadPoolSize = 1
        let system = await ClusterSystem(settings: settings)
        let receptionist = system.receptionist
        let node = system.cluster.node
        try await system.shutdown().wait()
        await receptionist.whenLocal { isolatedReceptionist in
            isolatedReceptionist.pruneClusterMember(removedNode: node)
            isolatedReceptionist.pruneClusterMember(removedNode: node)
        }
    }
}
