@testable import IMV2ServerApp
import IMV2ServerInfrastructure
import Testing

@Suite("Coverage authorization frontdoor composition")
struct GatewayFrontdoorAssemblyTests {
    @Test("logical aliases reserve only existing physical recovery slots within the read queue")
    func coverageQueueReservationUsesPhysicalStores() throws {
        let a = try V2RoomShardStorageConfiguration(shardID: "a", databaseURL: "postgres://fixture/one")
        let alias = try V2RoomShardStorageConfiguration(shardID: "b", databaseURL: a.databaseURL)
        let other = try V2RoomShardStorageConfiguration(shardID: "c", databaseURL: "postgres://fixture/two")
        #expect(GatewayFrontdoorAssembly.coverageReservedQueued(roomShardStorage: [a, alias], maximumReadQueued: 384) == 4)
        #expect(GatewayFrontdoorAssembly.coverageReservedQueued(roomShardStorage: [a, alias, other], maximumReadQueued: 384) == 8)
        #expect(GatewayFrontdoorAssembly.coverageReservedQueued(roomShardStorage: [a, other], maximumReadQueued: 4) == 3)
        #expect(GatewayFrontdoorAssembly.coverageReservedQueued(roomShardStorage: [a], maximumReadQueued: 1) == 0)
        #expect(GatewayFrontdoorAssembly.coverageReservedQueued(roomShardStorage: [], maximumReadQueued: 384) == 0)
    }
}
