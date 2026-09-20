import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("Routed group messaging store")
struct V2RoutedGroupMessagingStoreTests {
    @Test("Malformed manifest pages are rejected before owner writes and can resume with the original prefix",
          arguments: ["empty", "over-count", "early-final", "extra-page", "duplicate", "oversized", "repeated", "overlap"])
    func rejectsMalformedManifestPages(scenario: String) async throws {
        let expectedCount = scenario == "oversized" ? 600 : 3
        let members = try (1...max(4, expectedCount)).map { try UserID(String(format: "00000000-0000-0000-0000-%012x", $0)) }
        let intentStore = GroupCreationIntentStoreFake()
        let owner = GroupCreationOwnerStoreFake()
        let routed = try V2RoutedGroupMessagingStore(intentStore: intentStore, ownerStores: ["rooms-a": owner])
        let command = try V2StagedGroupRoomCommand(actorUserID: members[0], operationID: .init(uuid: UUID()),
            title: "manifest", capacityClass: .standard, stagedMemberCount: expectedCount - 1)
        let ids = try groupCreationIDs(suffix: "e")
        var slices: [V2GroupRoomCreationManifestSlice]
        switch scenario {
        case "empty": slices = [.init(memberUserIDs: [], hasMore: false)]
        case "over-count": slices = [.init(memberUserIDs: members, hasMore: false)]
        case "early-final": slices = [.init(memberUserIDs: [members[0]], hasMore: false)]
        case "extra-page": slices = [.init(memberUserIDs: Array(members.prefix(3)), hasMore: true)]
        case "duplicate": slices = [.init(memberUserIDs: [members[0], members[0]], hasMore: true)]
        case "oversized": slices = [.init(memberUserIDs: Array(members.prefix(513)), hasMore: true)]
        case "repeated": slices = [.init(memberUserIDs: [members[0]], hasMore: true), .init(memberUserIDs: [members[0]], hasMore: true)]
        default: slices = [.init(memberUserIDs: [members[0]], hasMore: true), .init(memberUserIDs: [members[0], members[2]], hasMore: false)]
        }
        await intentStore.configureSlices(slices)
        let profile = try groupCreationProfile(maxMembers: 1_000)
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        await #expect(throws: V2GroupRoomCreationIntentStoreError.corruptPersistenceState) {
            try await routed.createStaged(command: command, capacityProfile: profile, roomShardID: "ignored",
                roomID: ids.roomID, eventID: ids.eventID, now: now)
        }
        let prefixCount = scenario == "repeated" || scenario == "overlap" ? 1 : 0
        #expect(await owner.stagedPages().count == prefixCount)
        #expect(await intentStore.sliceReadCount() == prefixCount + 1)
        #expect(await intentStore.finalizedRoomIDs().isEmpty)
        // Retry preserves any already transferred page and the original IDs.
        if prefixCount == 1 {
            slices = [.init(memberUserIDs: [members[0]], hasMore: true), .init(memberUserIDs: [members[1], members[2]], hasMore: false)]
        } else if scenario == "oversized" {
            slices = [.init(memberUserIDs: Array(members.prefix(512)), hasMore: true), .init(memberUserIDs: Array(members.dropFirst(512)), hasMore: false)]
        } else {
            slices = [.init(memberUserIDs: Array(members.prefix(3)), hasMore: false)]
        }
        await intentStore.configureSlices(slices)
        let recovered = try await routed.createStaged(command: command, capacityProfile: profile, roomShardID: "ignored",
            roomID: ids.roomID, eventID: ids.eventID, now: now)
        guard case .created(let group) = recovered else { throw V2GroupRoomCreationIntentStoreError.corruptPersistenceState }
        #expect(group.roomID == ids.roomID && group.memberCount == expectedCount)
        #expect(await intentStore.finalizedRoomIDs() == [ids.roomID])
        if prefixCount == 1 {
            let pages = await owner.stagedPages()
            #expect(pages.count == 3 && pages[0] == pages[1] && pages[2].isFinal)
        }
    }

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
            now: .init(timeIntervalSince1970: 200)
        )

        let result = try await routed.create(
            command: makeGroupCommand(title: "被修改的群名"),
            capacityProfile: profile,
            roomShardID: "rooms-a",
            roomID: try .init("00000000-0000-0000-0000-00000000d003"),
            eventID: try .init("00000000-0000-0000-0000-00000000d004"),
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
            capacityClass: .large,
            stagedMemberCount: 599
        )
        let ids = try groupCreationIDs(suffix: "e")
        let outcome = try await routed.createStaged(
            command: command,
            capacityProfile: try groupCreationProfile(maxMembers: 1_000),
            roomShardID: "ignored",
            roomID: ids.roomID,
            eventID: ids.eventID,
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
    private var scriptedSlices: [V2GroupRoomCreationManifestSlice]?
    private var reads = 0

    func configureSlices(_ slices: [V2GroupRoomCreationManifestSlice]) { scriptedSlices = slices; reads = 0 }
    func sliceReadCount() -> Int { reads }

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
        reads += 1
        if var slices = scriptedSlices {
            guard !slices.isEmpty else { return .init(memberUserIDs: [], hasMore: false) }
            let first = slices.removeFirst()
            scriptedSlices = slices
            return first
        }
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
        now: Date
    ) throws -> V2CreateGroupRoomOutcome {
        try record(
            command: command,
            roomShardID: roomShardID,
            roomID: roomID,
            eventID: eventID,

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
        now: Date
    ) throws -> V2CreateGroupRoomOutcome {
        guard validatedMemberUserIDs == command.allMemberUserIDs else {
            return .invalidMembers
        }
        return try record(
            command: command,
            roomShardID: roomShardID,
            roomID: roomID,
            eventID: eventID,

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
    ) throws -> V2CreateGroupRoomOutcome {
        guard stagedIntent == intent else { return .unavailable }
        return .created(try .init(
            roomID: intent.roomID,
            ownerUserID: command.actorUserID,
            title: command.title,
            capacityClass: command.capacityClass,
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

        now: Date
    ) throws -> V2CreateGroupRoomOutcome {
        recorded.append(.init(
            roomID: roomID,
            eventID: eventID,

            roomShardID: roomShardID
        ))
        return .created(try .init(
            roomID: roomID,
            ownerUserID: command.actorUserID,
            title: command.title,
            capacityClass: command.capacityClass,
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
        capacityClass: .standard,
        initialMemberUserIDs: [
            .init("00000000-0000-0000-0000-00000000f003"),
        ]
    )
}

private func groupCreationIDs(
    suffix: Character
) throws -> (roomID: RoomID, eventID: EventID) {
    try (
        .init("00000000-0000-0000-0000-00000000\(suffix)003"),
        .init("00000000-0000-0000-0000-00000000\(suffix)004")
    )
}

private func groupCreationProfile(
    maxMembers: Int = 100
) throws -> V2CapacityProfile {
    try .init(id: "standard", limits: .init(
        maxEligibleMembers: maxMembers,
        maxCommandsPerWindow: 100,

        retryAfterSeconds: 1
    ))
}
