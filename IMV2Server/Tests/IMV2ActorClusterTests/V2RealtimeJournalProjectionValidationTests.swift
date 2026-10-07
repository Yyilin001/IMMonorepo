import Foundation
import Testing
import IMV2ActorContracts
import IMV2Core
@testable import IMV2ActorCluster

@Suite("Journal projection transport receipt domains")
struct V2RealtimeJournalProjectionValidationTests {
    @Test func baselineRequiresActualInstalledCutWithoutPublisherGrant() throws {
        let source = V2RealtimeJournalSource(sourceID: "room", incarnationID: UUID(), partitionID: 0)
        let fence = V2RealtimeJournalProjectionFence(publisherIncarnationID: UUID(), sourceLeaseEpoch: 1,
            sourceLeaseToken: UUID(), sourceLeaseExpiresAt: Date(), routingPartitionEpoch: 1,
            routingLeaseToken: UUID(), sessionID: UUID(), interestGeneration: 1, gatewayIncarnationID: UUID())
        let batch = V2RealtimeJournalProjectionBatch(source: source, fence: fence, payload: .baseline(minimumCut: 7))
        try validateJournalProjectionBatch(batch, limits: .init())
        try validateJournalProjectionReceipt(.applied(.init(batchID: batch.batchID, source: source,
            fence: fence, appliedThrough: 9, snapshotInstalled: true)), batch: batch)
        try validateJournalProjectionReceipt(.snapshotRequired, batch: batch)
        for (cut, installed) in [(6, true), (7, false)] {
            #expect(throws: V2ActorAuthenticationError.wrongRecipient) {
                try validateJournalProjectionReceipt(.applied(.init(batchID: batch.batchID, source: source,
                    fence: fence, appliedThrough: Int64(cut), snapshotInstalled: installed)), batch: batch)
            }
        }
        #expect(throws: V2ActorAuthenticationError.invalidRequest) {
            try validateJournalProjectionBatch(.init(source: source, fence: fence, payload: .baseline(minimumCut: -1)), limits: .init())
        }
        #expect(throws: V2ActorAuthenticationError.wrongRecipient) {
            try validateJournalProjectionReceipt(.headsApplied(.init(batchID: batch.batchID, source: source, fence: fence)), batch: batch)
        }
    }

    @Test func userControlHintCarriesVersionAndDeviceOnly() throws {
        let source = V2RealtimeJournalSource(sourceID: "user", incarnationID: UUID(), partitionID: 0)
        let fence = V2RealtimeJournalProjectionFence(publisherIncarnationID: UUID(), sourceLeaseEpoch: 1,
            sourceLeaseToken: UUID(), sourceLeaseExpiresAt: Date(), routingPartitionEpoch: 1,
            routingLeaseToken: UUID(), sessionID: UUID(), interestGeneration: 1, gatewayIncarnationID: UUID())
        let user = UserID(uuid: UUID()), device = UUID()
        let entry = V2RealtimeJournalProjectionEntry(sequence: 1,
            change: .userControlInvalidation(userID: user, controlVersion: 1, deviceID: device))
        try validateJournalProjectionBatch(.init(source: source, fence: fence,
            payload: .changes(fromExclusive: 0, throughInclusive: 1, entries: [entry])), limits: .init())
        let membership = V2RealtimeJournalProjectionEntry(sequence: 1,
            change: .userControlInvalidation(userID: user, controlVersion: 2, deviceID: nil,
                membershipRoomID: RoomID(uuid: UUID())))
        try validateJournalProjectionBatch(.init(source: source, fence: fence,
            payload: .changes(fromExclusive: 0, throughInclusive: 1, entries: [membership])), limits: .init())
        let encoded = try JSONEncoder().encode(membership)
        #expect(try JSONDecoder().decode(V2RealtimeJournalProjectionEntry.self, from: encoded) == membership)
        let malformedRoom = V2RealtimeJournalProjectionEntry(sequence: 1,
            change: .userControlInvalidation(userID: user, controlVersion: 2, deviceID: nil,
                membershipRoomID: try RoomID("invalid")))
        #expect(throws: V2ActorAuthenticationError.invalidRequest) {
            try validateJournalProjectionBatch(.init(source: source, fence: fence,
                payload: .changes(fromExclusive: 0, throughInclusive: 1, entries: [malformedRoom])), limits: .init())
        }
        let invalid = V2RealtimeJournalProjectionEntry(sequence: 1,
            change: .userControlInvalidation(userID: user, controlVersion: 0, deviceID: device))
        #expect(throws: V2ActorAuthenticationError.invalidRequest) {
            try validateJournalProjectionBatch(.init(source: source, fence: fence,
                payload: .changes(fromExclusive: 0, throughInclusive: 1, entries: [invalid])), limits: .init())
        }
    }

    @Test func headsCarryNoControlCheckpoint() throws {
        let source = V2RealtimeJournalSource(sourceID: "room", incarnationID: UUID(), partitionID: 0)
        let fence = V2RealtimeJournalProjectionFence(publisherIncarnationID: UUID(), sourceLeaseEpoch: 1,
            sourceLeaseToken: UUID(), sourceLeaseExpiresAt: Date(), routingPartitionEpoch: 1,
            routingLeaseToken: UUID(), sessionID: UUID(), interestGeneration: 1, gatewayIncarnationID: UUID())
        let batch = V2RealtimeJournalProjectionBatch(source: source, fence: fence,
            payload: .heads([.init(roomID: RoomID(uuid: UUID()), highWatermark: 90, ownerEpoch: 0, controlVersion: 0)]))
        try validateJournalProjectionBatch(batch, limits: .init())
        try validateJournalProjectionReceipt(.headsApplied(.init(batchID: batch.batchID, source: source, fence: fence)), batch: batch)
        #expect(throws: V2ActorAuthenticationError.wrongRecipient) {
            try validateJournalProjectionReceipt(.applied(.init(batchID: batch.batchID, source: source, fence: fence,
                appliedThrough: 90, snapshotInstalled: false)), batch: batch)
        }
        let control = V2RealtimeJournalProjectionBatch(source: source, fence: fence,
            payload: .changes(fromExclusive: 0, throughInclusive: 3, entries: []))
        #expect(throws: V2ActorAuthenticationError.wrongRecipient) {
            try validateJournalProjectionReceipt(.applied(.init(batchID: control.batchID, source: source, fence: fence,
                appliedThrough: 90, snapshotInstalled: false)), batch: control)
        }
    }
}
