import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("V2 direct messaging service")
struct V2DirectMessagingServiceTests {
    @Test("Stranger quota windows reject non-finite and unencodable durations")
    func strangerWindowConfigurationBounds() throws {
        for window in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude,
                       Double(Int64.max) / 1_000_000, 0, -1] {
            #expect(throws: V2DirectMessagingPolicyError.invalidLimit) {
                try V2StrangerMessagePolicy(maximumMessagesPerWindow: 3, window: window)
            }
        }
        for window in [0.0000001, 0.1234567, 86_400] {
            #expect(try V2StrangerMessagePolicy(maximumMessagesPerWindow: 3, window: window).window == window)
        }
    }





    @Test("direct shard route has fixed cross-binary vectors")
    func directShardRouteHasFixedVectors() throws {
        let router = try V2DirectRoomShardRouter(rawValue: "rooms-00,rooms-01,rooms-02,rooms-03")
        #expect(router.shardIDs == ["rooms-00", "rooms-01", "rooms-02", "rooms-03"])
        #expect(router.shardID(
            for: try .init("00000000-0000-0000-0000-000000000811"),
            and: try .init("00000000-0000-0000-0000-000000000812")
        ) == "rooms-00")
        #expect(router.shardID(
            for: try .init("00000000-0000-0000-0000-000000000001"),
            and: try .init("00000000-0000-0000-0000-000000000005")
        ) == "rooms-03")
    }

    @Test("room-owner direct route fence is valid PostgreSQL text")
    func roomOwnerRouteLockKeyIsTextSafe() {
        let lower = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let higher = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let key = roomOwnerDirectRouteLockKey(.init(lower: lower, higher: higher))

        #expect(!key.utf8.contains(0))
        #expect(key == "room-route:00000000-0000-0000-0000-000000000001:00000000-0000-0000-0000-000000000002")
    }

    @Test("rejects malformed or duplicate direct shard pools")
    func rejectsInvalidShardPools() throws {
        for pool in ["rooms-00,,rooms-01", "rooms-00,rooms-00"] {
            #expect(throws: V2DirectRoomShardRouter.Error.invalidShardIDs) { try V2DirectRoomShardRouter(rawValue: pool) }
        }
    }


    @Test("rejects opening a direct room with oneself before persistence")
    func rejectsSelfTarget() throws {
        let user = UserID(uuid: UUID())
        #expect(throws: V2DirectRoomOperationValidationError.invalidCommand) {
            try V2DirectRoomOperationCommand(actorUserID: user, operationID: .init(uuid: UUID()), targetUserID: user, firstSubmissionDeadlineMilliseconds: 1_750_000_600_000)
        }
    }






    private func profile() throws -> V2CapacityProfile {
        try .init(id: "standard", limits: .init(maxEligibleMembers: 10, maxCommandsPerWindow: 10,    retryAfterSeconds: 1))
    }
}
