@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2Core
import Synchronization
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing

@Suite("V2 room write service")
struct V2SendMessageServiceTests {
    @Test("UUIDv7 timestamps reject invalid clocks before conversion or monotonic state changes")
    func orderedIdentifierClockBounds() throws {
        let generator = V2SecureProcessUUIDGenerator()
        let factory = V2AcceptanceIDFactory()
        let base = Date(timeIntervalSince1970: 1_750_000_000)
        _ = try generator.makeOrderedPair(at: base)
        let invalidSeconds: [Double] = [.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, -1, 1e14, -1e14, -1e12, 281_474_976_710.656, 946_684_800 - 211_813_488_000, 946_684_800 + 9_223_371_331_200 - 10]
        for seconds in invalidSeconds {
            let invalid = Date(timeIntervalSince1970: seconds)
            #expect(throws: V2AcceptanceIdentifierError.invalidTimestamp) { try generator.makeOrderedPair(at: invalid) }
            #expect(throws: V2AcceptanceIdentifierError.invalidTimestamp) { try factory.make(at: invalid) }
        }
        let recovered = try generator.makeOrderedPair(at: base.addingTimeInterval(-60))
        var uuid = recovered.0.uuid
        let milliseconds = withUnsafeBytes(of: &uuid) { $0.prefix(6).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } }
        #expect(milliseconds == 1_750_000_000_000)
        _ = try factory.make(at: base)
    }

    @Test("UUIDv7 finite endpoints and fractional milliseconds preserve all 48 timestamp bits")
    func orderedIdentifierTimestampEndpoints() throws {
        let cases: [(Double, UInt64)] = [(0, 0), (1.2345, 1_234), (1_750_000_000.125, 1_750_000_000_125), (281_474_976_710.655, 0x0000_ffff_ffff_ffff)]
        for (seconds, expected) in cases {
            // Keep the extreme valid future timestamp out of the shared production generator.
            let generator = V2SecureProcessUUIDGenerator()
            let pair = try generator.makeOrderedPair(at: Date(timeIntervalSince1970: seconds))
            #expect(Set([pair.0, pair.1]).count == 2)
            for value in [pair.0, pair.1] {
                var uuid = value.uuid
                withUnsafeBytes(of: &uuid) { bytes in
                    #expect(bytes[6] >> 4 == 7)
                    #expect(bytes[8] & 0xc0 == 0x80)
                    #expect(bytes.prefix(6).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } == expected)
                }
            }
        }
    }

    @Test("secure process identifiers are concurrent-safe and accepted identifiers are UUIDv7")
    func secureProcessIdentifiersAreUniqueAndOrdered() async throws {
        let generator = V2SecureProcessUUIDGenerator()
        let values = await withTaskGroup(of: [UUID].self, returning: [UUID].self) { group in
            for _ in 0..<8 {
                group.addTask {
                    (0..<256).map { _ in generator.makeOne() }
                }
            }
            var result: [UUID] = []
            result.reserveCapacity(2_048)
            for await batch in group { result.append(contentsOf: batch) }
            return result
        }

        #expect(Set(values).count == values.count)
        for value in values {
            var uuid = value.uuid
            withUnsafeBytes(of: &uuid) { bytes in
                #expect(bytes[6] >> 4 == 4)
                #expect(bytes[8] & 0xc0 == 0x80)
            }
        }
        let acceptedAt = Date(timeIntervalSince1970: 1_645_557_742)
        let pair = try generator.makeOrderedPair(at: acceptedAt)
        #expect(Set([pair.0, pair.1]).count == 2)
        for value in [pair.0, pair.1] {
            var uuid = value.uuid
            withUnsafeBytes(of: &uuid) { bytes in
                #expect(bytes[6] >> 4 == 7)
                #expect(bytes[8] & 0xc0 == 0x80)
                let milliseconds = bytes.prefix(6).reduce(UInt64(0)) {
                    ($0 << 8) | UInt64($1)
                }
                #expect(milliseconds == 1_645_557_742_000)
            }
        }

        // A local wall-clock correction cannot move subsequently generated
        // identifiers into an older B-tree range.
        let afterClockRollback = try generator.makeOrderedPair(
            at: acceptedAt.addingTimeInterval(-60)
        ).0
        var rollbackUUID = afterClockRollback.uuid
        let rollbackMilliseconds = withUnsafeBytes(of: &rollbackUUID) { bytes in
            bytes.prefix(6).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        }
        #expect(rollbackMilliseconds == 1_645_557_742_000)

        // The production path expands one 256-bit HMAC result into two
        // disjoint UUIDv7 random regions. Exercise that shared generator under
        // contention so a future layout change cannot overlap regions or
        // reuse a counter value unnoticed.
        let pairs = try await withThrowingTaskGroup(
            of: [(UUID, UUID)].self,
            returning: [(UUID, UUID)].self
        ) { group in
            for _ in 0..<8 {
                group.addTask {
                    try (0..<256).map { _ in
                        try generator.makeOrderedPair(at: acceptedAt)
                    }
                }
            }
            var result: [(UUID, UUID)] = []
            result.reserveCapacity(2_048)
            for try await batch in group { result.append(contentsOf: batch) }
            return result
        }
        let flattened = pairs.flatMap { [$0.0, $0.1] }
        #expect(Set(flattened).count == flattened.count)
        for value in flattened {
            var uuid = value.uuid
            withUnsafeBytes(of: &uuid) { bytes in
                #expect(bytes[6] >> 4 == 7)
                #expect(bytes[8] & 0xc0 == 0x80)
            }
        }
    }

    @Test("authenticated actor is persisted as the message sender and retry is idempotent")
    func authenticatedActorAndRetry() async throws {
        let fixture = try Fixture()
        let store = InMemoryV2RoomWriteStore(seed: [(fixture.roomState, fixture.shardState)], authorizedActors: [fixture.senderID])
        let service = V2SendMessageService(
            store: store,
            capacityProfile: try .init(id: "standard", limits: fixture.profile),
            limits: try V2MessageCommandLimits(maxUTF8Bytes: 64),
            idFactory: V2AcceptanceIDFactory(makeUUID: fixture.nextUUID),
            now: { fixture.now }
        )
        let request = V2AuthenticatedSendMessage(
            roomID: fixture.roomID,
            actorUserID: fixture.senderID,
            clientMessageID: fixture.clientMessageID,
            text: "hello V2"
        )

        let first = try await service.send(request)
        let retry = try await service.send(request)

        guard case .accepted(let accepted) = first else {
            Issue.record("first send must be accepted")
            return
        }
        #expect(accepted.senderUserID == fixture.senderID)
        #expect(retry == .idempotent(accepted.receipt))
        let state = try #require(await store.state(for: fixture.roomID))
        #expect(state.0.nextRoomSequence == 2)
    }



    @Test("a new command from a non-member is rejected before capacity is consumed")
    func nonMemberCannotSend() async throws {
        let fixture = try Fixture()
        let store = InMemoryV2RoomWriteStore(seed: [(fixture.roomState, fixture.shardState)], authorizedActors: [])
        let service = V2SendMessageService(
            store: store,
            capacityProfile: try .init(id: "standard", limits: fixture.profile),
            limits: try .init(maxUTF8Bytes: 64),
            now: { fixture.now }
        )

        await #expect(throws: V2RoomWriteStoreError.actorNotEligible) {
            _ = try await service.send(.init(roomID: fixture.roomID, actorUserID: fixture.senderID, clientMessageID: fixture.clientMessageID, text: "forbidden"))
        }
        let state = try #require(await store.state(for: fixture.roomID))
        #expect(state.0.nextRoomSequence == 1)
        #expect(state.0.admission.commandWindow.used == 0)
    }

    @Test("a room cannot use a process-wide profile with the wrong persisted identifier")
    func capacityProfileMustMatchRoomBinding() async throws {
        let fixture = try Fixture()
        let store = InMemoryV2RoomWriteStore(seed: [(fixture.roomState, fixture.shardState)], authorizedActors: [fixture.senderID], capacityProfileID: "standard")
        let service = V2SendMessageService(
            store: store,
            capacityProfile: try .init(id: "premium", limits: fixture.profile),
            limits: try .init(maxUTF8Bytes: 64),
            now: { fixture.now }
        )
        let request = V2AuthenticatedSendMessage(roomID: fixture.roomID, actorUserID: fixture.senderID, clientMessageID: fixture.clientMessageID, text: "wrong profile")

        await #expect(throws: V2RoomWriteStoreError.capacityProfileMismatch) {
            try await service.send(request)
        }
        let state = try #require(await store.state(for: fixture.roomID))
        #expect(state.0.nextRoomSequence == 1)
    }

}

private struct Fixture: Sendable {
    let roomID = try! RoomID("00000000-0000-0000-0000-000000000001")
    let senderID = try! UserID("00000000-0000-0000-0000-000000000002")
    let clientMessageID = try! ClientMessageID("00000000-0000-0000-0000-000000000003")
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    var profile: RoomCapacityProfile
    let roomState: V2RoomCommandState
    let shardState: ShardAdmissionState

    init() throws {
        profile = try RoomCapacityProfile(maxEligibleMembers: 10, maxCommandsPerWindow: 10,    retryAfterSeconds: 7)
        roomState = try V2RoomCommandState(roomID: roomID, nextRoomSequence: 1, admission: .init(eligibleMemberCount: 3, commandWindow: .init(limit: 10)))
        shardState = try ShardAdmissionState(lease: .init(id: try ShardAdmissionLeaseID("00000000-0000-0000-0000-000000000004"), generation: 1, validUntil: now.addingTimeInterval(60), commandWindow: .init(limit: 10)))
    }

    func nextUUID() -> UUID { UUID() }
}
