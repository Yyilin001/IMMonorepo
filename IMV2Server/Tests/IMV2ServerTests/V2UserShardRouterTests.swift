@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing

struct V2UserShardRouterTests {
    @Test("single-shard router returns the explicitly configured route in input order")
    func returnsConfiguredRoute() async throws {
        let route = try V2UserShardRoute(bucket: "users-primary", observedRouterEpoch: 12)
        let users = [
            try UserID("00000000-0000-0000-0000-000000000971"),
            try UserID("00000000-0000-0000-0000-000000000972"),
        ]

        #expect(try await V2SingleUserShardRouter(route: route).routes(for: users) == [route, route])
    }

    @Test("routes reject blank buckets and negative epochs")
    func validatesRoute() {
        #expect(throws: V2UserShardRouterError.invalidRoute) {
            _ = try V2UserShardRoute(bucket: " ", observedRouterEpoch: 0)
        }
        #expect(throws: V2UserShardRouterError.invalidRoute) {
            _ = try V2UserShardRoute(bucket: "users-primary", observedRouterEpoch: -1)
        }
    }
}
