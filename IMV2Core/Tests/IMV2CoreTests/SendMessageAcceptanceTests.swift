import Foundation
import Testing
@testable import IMV2Core

struct SendMessageAcceptanceTests {
    @Test
    func successfulAcceptanceProducesOneAtomicWriteSet() throws {
        let state = try initialRoomState()
        let command = try command(clientMessageID: "client-1", text: "hello")

        let result = try V2SendMessageReducer.reduce(
            command: command,
            roomState: state,
            shardState: try shardState(),
            profile: try profile(),
            identifiers: try identifiers(),
            now: Date(timeIntervalSince1970: 1_000)
        )

        guard case let .accepted(transaction) = result else {
            Issue.record("Expected acceptance")
            return
        }
        #expect(transaction.acceptedMessage.roomSequence == 1)
        #expect(transaction.fanoutPlan.reservation.cost.targetCount == 2)
        #expect(transaction.nextRoomState.nextRoomSequence == 2)
        #expect(transaction.nextRoomState.acceptedCommands.count == 1)
        #expect(transaction.nextRoomState.admission.outstandingFanoutUnits == 2)
        #expect(transaction.nextShardState.outstandingFanoutUnits == 2)
    }

    @Test
    func retryReturnsOriginalAcceptedMessageWithoutAdditionalCapacity() throws {
        let command = try command(clientMessageID: "client-1", text: "hello")
        let first = try V2SendMessageReducer.reduce(
            command: command,
            roomState: try initialRoomState(),
            shardState: try shardState(),
            profile: try profile(),
            identifiers: try identifiers(),
            now: Date(timeIntervalSince1970: 1_000)
        )
        guard case let .accepted(transaction) = first else {
            Issue.record("Expected first acceptance")
            return
        }

        let retry = try V2SendMessageReducer.reduce(
            command: command,
            roomState: transaction.nextRoomState,
            shardState: transaction.nextShardState,
            profile: try profile(),
            identifiers: try V2AcceptanceIdentifiers(
                messageID: MessageID("message-should-not-be-used"),
                eventID: EventID("event-should-not-be-used"),
                planID: FanoutPlanID("plan-should-not-be-used")
            ),
            now: Date(timeIntervalSince1970: 2_000)
        )

        #expect(retry == .idempotent(transaction.acceptedMessage))
    }

    @Test("only materialized messages carry attachment presentation facts")
    func acceptedDraftMaterializesExactAttachmentPresentations() throws {
        let mediaID = try MediaID("00000000-0000-0000-0000-000000000401")
        let result = try V2SendMessageReducer.reduce(
            command: try V2SendMessageCommand(
                roomID: RoomID("room-1"),
                senderUserID: UserID("user-1"),
                clientMessageID: ClientMessageID("client-media"),
                text: "",
                media: [.init(mediaID: mediaID)],
                limits: try .init(maxUTF8Bytes: 128)
            ),
            roomState: try initialRoomState(),
            shardState: try shardState(),
            profile: try profile(),
            identifiers: try identifiers(),
            now: Date(timeIntervalSince1970: 1_000)
        )
        guard case let .accepted(transaction) = result else {
            Issue.record("Expected acceptance")
            return
        }

        let presentation = try V2MediaPresentation(
            mediaID: mediaID,
            kind: .image,
            contentType: "image/jpeg",
            byteCount: 42
        )
        let accepted = transaction.acceptedMessage.materialized(mediaPresentations: [presentation])

        #expect(accepted.media == [.init(mediaID: mediaID)])
        #expect(accepted.mediaPresentations == [presentation])
    }

    @Test
    func capacityRejectionDoesNotAllocateSequenceOrDedupeRecord() throws {
        var profile = try profile()
        profile = try RoomCapacityProfile(
            maxEligibleMembers: profile.maxEligibleMembers,
            maxCommandsPerWindow: profile.maxCommandsPerWindow,
            maxFanoutUnitsPerWindow: profile.maxFanoutUnitsPerWindow,
            maxOutstandingFanoutUnits: 1,
            maxOutstandingPlans: profile.maxOutstandingPlans,
            maxEnumerationPageSize: profile.maxEnumerationPageSize,
            maxPlannerConcurrency: profile.maxPlannerConcurrency,
            maxDeliveryConcurrency: profile.maxDeliveryConcurrency,
            retryAfterSeconds: profile.retryAfterSeconds
        )
        let state = try initialRoomState()

        let result = try V2SendMessageReducer.reduce(
            command: try command(clientMessageID: "client-1", text: "hello"),
            roomState: state,
            shardState: try shardState(),
            profile: profile,
            identifiers: try identifiers(),
            now: Date()
        )

        #expect(result == .rateLimited(retryAfterSeconds: profile.retryAfterSeconds))
        #expect(state.nextRoomSequence == 1)
        #expect(state.acceptedCommands.isEmpty)
    }

    private func command(clientMessageID: String, text: String) throws -> V2SendMessageCommand {
        try V2SendMessageCommand(
            roomID: RoomID("room-1"),
            senderUserID: UserID("user-1"),
            clientMessageID: ClientMessageID(clientMessageID),
            text: text,
            limits: try V2MessageCommandLimits(maxUTF8Bytes: 128)
        )
    }

    private func initialRoomState() throws -> V2RoomCommandState {
        try V2RoomCommandState(
            roomID: RoomID("room-1"),
            nextRoomSequence: 1,
            admission: RoomAdmissionState(
                eligibleMemberCount: 2,
                commandWindow: try CapacityWindow(limit: 10),
                fanoutWindow: try CapacityWindow(limit: 100),
                outstandingFanoutUnits: 0,
                outstandingPlans: 0
            )
        )
    }

    private func shardState() throws -> ShardAdmissionState {
        try ShardAdmissionState(
            lease: ShardAdmissionLease(
                id: ShardAdmissionLeaseID("lease-1"),
                generation: 1,
                validUntil: .distantFuture,
                commandWindow: try CapacityWindow(limit: 10),
                fanoutWindow: try CapacityWindow(limit: 100),
                maxOutstandingFanoutUnits: 100,
                maxOutstandingPlans: 10
            ),
            outstandingFanoutUnits: 0,
            outstandingPlans: 0
        )
    }

    private func profile() throws -> RoomCapacityProfile {
        try RoomCapacityProfile(
            maxEligibleMembers: 100,
            maxCommandsPerWindow: 10,
            maxFanoutUnitsPerWindow: 100,
            maxOutstandingFanoutUnits: 100,
            maxOutstandingPlans: 10,
            maxEnumerationPageSize: 10,
            maxPlannerConcurrency: 2,
            maxDeliveryConcurrency: 4,
            retryAfterSeconds: 3
        )
    }

    private func identifiers() throws -> V2AcceptanceIdentifiers {
        try V2AcceptanceIdentifiers(
            messageID: MessageID("message-1"),
            eventID: EventID("event-1"),
            planID: FanoutPlanID("plan-1")
        )
    }
}
