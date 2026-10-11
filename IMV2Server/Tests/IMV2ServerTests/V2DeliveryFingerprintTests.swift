import Foundation
import IMV2Core
import IMV2ActorContracts
import Testing
@testable import IMV2ServerGateway

@Suite("Delivery fingerprint canonical bytes")
struct V2DeliveryFingerprintTests {
    @Test func allPayloadsPreserveCanonicalDigest() throws {
        func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }
        let room = RoomID(uuid: id(1)), user = UserID(uuid: id(4))
        let activation = try V2RoomActivationToken(roomID: room, owner: .init(shardID: "rooms", epoch: 2),
            activationEpoch: .init(3), host: .init(hostID: .init("host"), incarnationID: id(2)))
        let fence = V2RoomSubscriptionFence(activation: activation, subscriptionID: id(3), generation: 4, baselineSequence: 5)
        let member = V2RoomSubscriptionMember(userID: user, memberRevision: 7)
        let event = V2RealtimeRoomEvent(roomID: room, highWatermark: 11, sourceEventID: .init(uuid: id(5)), roomSequence: 10,
            projectionKind: "消息😀", payload: Data([0,255,1]), recipientUserIDs: [.init(uuid: id(6)), user],
            groupMembershipRevision: 8, acceptedMembershipRevision: 9, excludedConnectionID: id(7))
        let payloads: [V2RoomSubscriptionPayload] = [.baseline(members: [member]), .baselinePage(index: 2, totalMembers: 1025, members: [member]),
            .grant(member: member, baselineSequence: 12), .broadcast(event), .event(event, members: [member]),
            .head(highWatermark: 13), .authorizationInvalidated, .revoke(userID: user, memberRevision: 14)]
        // Independently generated from the v1 tagged, length-prefixed, big-endian byte contract.
        let expected = [
            "93cf8762211a385dca7216b5d49acd69d65d704c72a409beaacc0ef05a96d64e",
            "7eea0f3ad6abf11bee867664448be729a4905edc156cd4e3e3f6d1b1b18c7e0f",
            "1cd7dce8d245c111d89d64cc75a0d7ecd84e36c220a355c1610b2ca7d50726b9",
            "51257c7e7e84cbe43bea0d5050a6167604355e5b7f0188accca5834d52c7394d",
            "d545b0d659a9ae3f59529f8a5844fce2a6d51699d9b7e7585b4b4ac54646ece7",
            "fee959194446f45754da6338ba15f7aea6e53bd4c797522a340949eff3899f0d",
            "acac1414fd461aa38ad8bf8486996b1ab0de6e5cbc6198daa347e465254a5041",
            "a9f67d744963ff3772dd149e8085610b2e8c477e2a12d64d3acf94c6b184bf0e",
        ]
        for (payload, digest) in zip(payloads, expected) {
            let delivery = V2RoomSubscriptionDelivery(fence: fence, deliverySequence: 6, authorizationSequence: 7, payload: payload)
            let actual = V2RoomSubscriptionDeliveryFingerprint.digest(delivery).map { String(format: "%02x", $0) }.joined()
            #expect(actual == digest)
        }
    }
}
