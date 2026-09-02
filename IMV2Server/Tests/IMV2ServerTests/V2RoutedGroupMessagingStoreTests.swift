import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("Routed group messaging store")
struct V2RoutedGroupMessagingStoreTests {
    @Test("a retry reuses its durable owner and generated identifiers")
    func retryReusesDurableIntent() async throws {
        let intentStore = GroupCreationIntentStoreFake()
        let firstOwner = GroupCreationOwnerStoreFake()
        let secondOwner = GroupCreationOwnerStoreFake()
        let routed = try V2RoutedGroupMessagingStore(
            intentStore: intentStore,
            ownerStores: [
                "rooms-a": firstOwner,
                "rooms-b": secondOwner,
            ]
        )
        let command = try makeGroupCommand(title: "真实群聊")
        let profile = try groupCreationProfile()
        let firstIDs = try groupCreationIDs(suffix: "a")

        let first = try await routed.create(
            command: command,
            capacityProfile: profile,
            roomShardID: "ignored-client-candidate",
            roomID: firstIDs.roomID,
            eventID: firstIDs.eventID,
            planID: firstIDs.planID,
            now: .init(timeIntervalSince1970: 100)
        )
        guard case .created(let firstGroup) = first else {
            Issue.record("expected created group")
            return
        }
        let retryIDs = try groupCreationIDs(suffix: "b")
        let retry = try await routed.create(
            command: command,
            capacityProfile: profile,
            roomShardID: "another-ignored-candidate",
            roomID: retryIDs.roomID,
            eventID: retryIDs.eventID,
            planID: retryIDs.planID,
            now: .init(timeIntervalSince1970: 101)
        )
        guard case .created(let retryGroup) = retry else {
            Issue.record("expected idempotent owner result")
            return
        }

        #expect(firstGroup.roomID == firstIDs.roomID)
        #expect(retryGroup.roomID == firstIDs.roomID)
        #expect(await intentStore.finalizedRoomIDs() == [
            firstIDs.roomID,
            firstIDs.roomID,
        ])
        let firstCalls = await firstOwner.calls()
        let secondCalls = await secondOwner.calls()
        let selectedCalls = firstCalls.isEmpty ? secondCalls : firstCalls
        let unselectedCalls = firstCalls.isEmpty ? firstCalls : secondCalls
        #expect(selectedCalls.map(\.roomID) == [firstIDs.roomID, firstIDs.roomID])
        #expect(selectedCalls.map(\.eventID) == [firstIDs.eventID, firstIDs.eventID])
        #expect(selectedCalls.map(\.planID) == [firstIDs.planID, firstIDs.planID])
        #expect(unselectedCalls.isEmpty)
    }

    @Test("the same operation with different normalized input is rejected before owner work")
    func changedInputConflictsBeforeOwner() async throws {
        let intentStore = GroupCreationIntentStoreFake()
        let owner = GroupCreationOwnerStoreFake()
        let routed = try V2RoutedGroupMessagingStore(
            intentStore: intentStore,
            ownerStores: ["rooms-a": owner]
        )
        let profile = try groupCreationProfile()
        let ids = try groupCreationIDs(suffix: "c")
        _ = try await routed.create(
            command: makeGroupCommand(title: "原始群名"),
            capacityProfile: profile,
            roomShardID: "rooms-a",
            roomID: ids.roomID,
            eventID: ids.eventID,
            planID: ids.planID,
            now: .init(timeIntervalSince1970: 200)
        )

        let result = try await routed.create(
            command: makeGroupCommand(title: "被修改的群名"),
            capacityProfile: profile,
            roomShardID: "rooms-a",
            roomID: try .init("00000000-0000-0000-0000-00000000d003"),
            eventID: try .init("00000000-0000-0000-0000-00000000d004"),
            planID: try .init("00000000-0000-0000-0000-00000000d005"),
            now: .init(timeIntervalSince1970: 201)
        )

        #expect(result == .idempotencyConflict)
        #expect(await owner.calls().count == 1)
    }

    @Test("staged audiences transfer bounded contiguous digest pages before owner commit")
    func stagedAudienceTransfersBoundedPages() async throws {
        let actor = try UserID(
            "00000000-0000-0000-0000-00000000e001"
        )
        var members = [actor]
        for _ in 0 ..< 599 { members.append(try .init(UUID().uuidString)) }
        members.sort()
        let intentStore = GroupCreationIntentStoreFake()
        await intentStore.configureStagedMembers(members)
        let owner = GroupCreationOwnerStoreFake()
        let routed = try V2RoutedGroupMessagingStore(
            intentStore: intentStore,
            ownerStores: ["rooms-a": owner]
        )
        let command = try V2StagedGroupRoomCommand(
            actorUserID: actor,
            operationID: .init(
                "00000000-0000-0000-0000-00000000e002"
            ),
            title: "六百人真实群",
            deliveryMode: .largeGroupHybrid,
            stagedMemberCount: 599
        )
        let ids = try groupCreationIDs(suffix: "e")
        let outcome = try await routed.createStaged(
            command: command,
            capacityProfile: try groupCreationProfile(maxMembers: 1_000),
            roomShardID: "ignored",
            roomID: ids.roomID,
            eventID: ids.eventID,
            planID: ids.planID,
            now: .init(timeIntervalSince1970: 300)
        )
        guard case .created(let group) = outcome else {
            Issue.record("expected staged group creation")
            return
        }
        #expect(group.roomID == ids.roomID)
        let pages = await owner.stagedPages()
        #expect(pages.map(\.pageNumber) == [0, 1])
        #expect(pages.map { $0.memberUserIDs.count } == [512, 88])
        #expect(pages.map(\.isFinal) == [false, true])
        #expect(Set(pages.flatMap(\.memberUserIDs)) == Set(members))
        #expect(await intentStore.finalizedRoomIDs() == [ids.roomID])
    }
}

private actor GroupCreationIntentStoreFake: V2GroupRoomCreationIntentStore {
    private var intent: V2GroupRoomCreationIntent?
    private var finalized: [RoomID] = []

    func prepare(
        _ candidate: V2GroupRoomCreationIntent,
        memberUserIDs: [UserID],
        now _: Date
    ) -> V2PrepareGroupRoomCreationIntentOutcome {
        guard let intent else {
            self.intent = candidate
            members = memberUserIDs.sorted()
            return .prepared(candidate)
        }
        guard intent.requestFingerprint == candidate.requestFingerprint else {
            return .idempotencyConflict
        }
        return .idempotent(intent)
    }

    func prepareStaged(
        _ candidate: V2GroupRoomCreationIntent,
        command _: V2StagedGroupRoomCommand,
        now _: Date
    ) -> V2PrepareGroupRoomCreationIntentOutcome {
        guard let intent else {
            self.intent = candidate
            return .prepared(candidate)
        }
        guard intent.requestFingerprint == candidate.requestFingerprint else {
            return .idempotencyConflict
        }
        return .idempotent(intent)
    }

    func configureStagedMembers(_ members: [UserID]) {
        self.members = members.sorted()
    }

    func memberUserIDs(
        for _: V2GroupRoomCreationIntent
    ) -> [UserID] { members }

    func memberUserIDSlice(
        for _: V2GroupRoomCreationIntent,
        afterUserID: UserID?,
        limit: Int
    ) -> V2GroupRoomCreationManifestSlice {
        let remaining = members.filter { userID in
            afterUserID.map { userID > $0 } ?? true
        }
        return .init(
            memberUserIDs: Array(remaining.prefix(limit)),
            hasMore: remaining.count > limit
        )
    }

    func finalizeCommitted(
        _ intent: V2GroupRoomCreationIntent,
        now _: Date
    ) throws -> V2GroupRoomCreationIntent {
        finalized.append(intent.roomID)
        return try .init(
            actorUserID: intent.actorUserID,
            operationID: intent.operationID,
            roomID: intent.roomID,
            eventID: intent.eventID,
            planID: intent.planID,
            roomShardID: intent.roomShardID,
            routeEpoch: intent.routeEpoch,
            requestFingerprint: intent.requestFingerprint,
            audienceMemberCount: intent.audienceMemberCount,
            state: .committed
        )
    }

    func finalizedRoomIDs() -> [RoomID] { finalized }

    private var members: [UserID] = []
}

private actor GroupCreationOwnerStoreFake:
    V2ControlValidatedStagedGroupMessagingStore
{
    struct Call: Equatable, Sendable {
        let roomID: RoomID
        let eventID: EventID
        let planID: FanoutPlanID
        let roomShardID: String
    }

    private var recorded: [Call] = []
    private var pages: [V2GroupRoomCreationManifestPage] = []
    private var stagedIntent: V2GroupRoomCreationIntent?

    func create(
        command: V2CreateGroupRoomCommand,
        capacityProfile _: V2CapacityProfile,
        roomShardID: String,
        roomID: RoomID,
        eventID: EventID,
        planID: FanoutPlanID,
        now: Date
    ) -> V2CreateGroupRoomOutcome {
        record(
            command: command,
            roomShardID: roomShardID,
            roomID: roomID,
            eventID: eventID,
            planID: planID,
            now: now
        )
    }

    func createControlValidated(
        command: V2CreateGroupRoomCommand,
        validatedMemberUserIDs: [UserID],
        capacityProfile _: V2CapacityProfile,
        roomShardID: String,
        roomID: RoomID,
        eventID: EventID,
        planID: FanoutPlanID,
        now: Date
    ) -> V2CreateGroupRoomOutcome {
        guard validatedMemberUserIDs == command.allMemberUserIDs else {
            return .invalidMembers
        }
        return record(
            command: command,
            roomShardID: roomShardID,
            roomID: roomID,
            eventID: eventID,
            planID: planID,
            now: now
        )
    }

    func stageControlValidatedAudience(
        intent: V2GroupRoomCreationIntent,
        page: V2GroupRoomCreationManifestPage,
        now _: Date
    ) {
        stagedIntent = intent
        pages.append(page)
    }

    func createControlValidatedStaged(
        command: V2StagedGroupRoomCommand,
        intent: V2GroupRoomCreationIntent,
        capacityProfile _: V2CapacityProfile,
        now: Date
    ) -> V2CreateGroupRoomOutcome {
        guard stagedIntent == intent else { return .unavailable }
        return .created(.init(
            roomID: intent.roomID,
            ownerUserID: command.actorUserID,
            title: command.title,
            deliveryMode: command.deliveryMode,
            memberUserIDs: [command.actorUserID],
            memberCount: command.allMemberCount,
            createdAt: now
        ))
    }

    func stagedPages() -> [V2GroupRoomCreationManifestPage] { pages }

    private func record(
        command: V2CreateGroupRoomCommand,
        roomShardID: String,
        roomID: RoomID,
        eventID: EventID,
        planID: FanoutPlanID,
        now: Date
    ) -> V2CreateGroupRoomOutcome {
        recorded.append(.init(
            roomID: roomID,
            eventID: eventID,
            planID: planID,
            roomShardID: roomShardID
        ))
        return .created(.init(
            roomID: roomID,
            ownerUserID: command.actorUserID,
            title: command.title,
            deliveryMode: command.deliveryMode,
            memberUserIDs: command.allMemberUserIDs,
            createdAt: now
        ))
    }

    func calls() -> [Call] { recorded }
}

private func makeGroupCommand(title: String) throws -> V2CreateGroupRoomCommand {
    try .init(
        actorUserID: .init("00000000-0000-0000-0000-00000000f001"),
        operationID: .init("00000000-0000-0000-0000-00000000f002"),
        title: title,
        deliveryMode: .standardFanout,
        initialMemberUserIDs: [
            .init("00000000-0000-0000-0000-00000000f003"),
        ]
    )
}

private func groupCreationIDs(
    suffix: Character
) throws -> (roomID: RoomID, eventID: EventID, planID: FanoutPlanID) {
    try (
        .init("00000000-0000-0000-0000-00000000\(suffix)003"),
        .init("00000000-0000-0000-0000-00000000\(suffix)004"),
        .init("00000000-0000-0000-0000-00000000\(suffix)005")
    )
}

private func groupCreationProfile(
    maxMembers: Int = 100
) throws -> V2CapacityProfile {
    try .init(id: "standard", limits: .init(
        maxEligibleMembers: maxMembers,
        maxCommandsPerWindow: 100,
        maxFanoutUnitsPerWindow: 10_000,
        maxOutstandingFanoutUnits: 10_000,
        maxOutstandingPlans: 100,
        maxEnumerationPageSize: 100,
        maxPlannerConcurrency: 2,
        maxDeliveryConcurrency: 2,
        retryAfterSeconds: 1
    ))
}
