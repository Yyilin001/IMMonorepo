import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("V2 routed read receipt store")
struct V2RoutedReadReceiptStoreTests {
    @Test("group receipt is recorded only by its durable room owner")
    func routesGroupReceiptToOwner() async throws {
        let fixture = try ReceiptFixture()
        let first = GroupReceiptStoreSpy(attempt: .notGroup)
        let second = GroupReceiptStoreSpy(attempt: .handled(
            .recorded(fixture.receipt)
        ))
        let control = RoutedReceiptControlSpy(receipt: fixture.receipt)
        let store = try V2RoutedReadReceiptStore(
            router: ReceiptRouter(routes: [
                fixture.roomID: try .init(shardID: "rooms-b", epoch: 3),
            ]),
            ownerStores: ["rooms-a": first, "rooms-b": second],
            controlStore: control
        )

        #expect(try await store.record(
            command: fixture.command,
            now: fixture.now
        ) == .recorded(fixture.receipt))
        #expect(await first.commands().isEmpty)
        #expect(await second.commands() == [fixture.command])
        #expect(await control.recordCommands().isEmpty)
    }

    @Test("direct room classification falls back to privacy-preserving control path")
    func directReceiptFallsBackToControl() async throws {
        let fixture = try ReceiptFixture()
        let owner = GroupReceiptStoreSpy(attempt: .notGroup)
        let control = RoutedReceiptControlSpy(receipt: fixture.receipt)
        let store = try V2RoutedReadReceiptStore(
            router: ReceiptRouter(routes: [
                fixture.roomID: try .init(shardID: "rooms-a", epoch: 0),
            ]),
            ownerStores: ["rooms-a": owner],
            controlStore: control
        )

        #expect(try await store.record(
            command: fixture.command,
            now: fixture.now
        ) == .recorded(fixture.receipt))
        #expect(await owner.commands() == [fixture.command])
        #expect(await control.recordCommands() == [fixture.command])
    }

    @Test("user preferences and reader disclosure remain on control authority")
    func retainsUserOwnedOperationsOnControl() async throws {
        let fixture = try ReceiptFixture()
        let control = RoutedReceiptControlSpy(receipt: fixture.receipt)
        let owner = GroupReceiptStoreSpy(attempt: .notGroup)
        let store = try V2RoutedReadReceiptStore(
            router: ReceiptRouter(routes: [
                fixture.roomID: try .init(shardID: "rooms-a", epoch: 0),
            ]),
            ownerStores: [
                "rooms-a": owner,
            ],
            controlStore: control
        )
        let preference = try V2SetReadReceiptPreferencesCommand(
            actorUserID: fixture.actorID,
            operationID: .init("00000000-0000-0000-0000-00000000e104"),
            allowsDirectReadReceipts: false,
            allowsGroupReadReceipts: false
        )

        _ = try await store.setPreferences(command: preference, now: fixture.now)
        let page = try await store.readers(
            roomID: fixture.roomID,
            messageID: .init("00000000-0000-0000-0000-00000000e105"),
            actorUserID: fixture.actorID,
            cursor: nil,
            pageSize: 25
        )

        #expect(await control.preferenceCommands() == [preference])
        #expect(await control.visibilityCallCount() == 1)
        #expect(page.roomID == fixture.roomID)
    }

    @Test("reader pagination scans owner candidates and filters with control privacy")
    func combinesRoomCandidatesWithControlVisibility() async throws {
        let fixture = try ReceiptFixture()
        let hidden = try UserID("00000000-0000-0000-0000-00000000e106")
        let visible = try UserID("00000000-0000-0000-0000-00000000e107")
        let message = try MessageID("00000000-0000-0000-0000-00000000e108")
        let identity = try V2PublicIdentity(
            userID: visible,
            handle: .init("visible_reader"),
            displayName: "Visible Reader",
            accountKind: .regular
        )
        let owner = GroupReceiptStoreSpy(
            attempt: .notGroup,
            candidatePages: [
                .init(
                    roomID: fixture.roomID,
                    messageID: message,
                    candidates: [.init(
                        userID: hidden, readThroughRoomSequence: 20
                    )],
                    nextCursor: "owner-cursor-1"
                ),
                .init(
                    roomID: fixture.roomID,
                    messageID: message,
                    candidates: [.init(
                        userID: visible, readThroughRoomSequence: 19
                    )],
                    nextCursor: nil
                ),
            ]
        )
        let control = RoutedReceiptControlSpy(
            receipt: fixture.receipt,
            visibleIdentities: [visible: identity]
        )
        let store = try V2RoutedReadReceiptStore(
            router: ReceiptRouter(routes: [
                fixture.roomID: try .init(shardID: "rooms-a", epoch: 0),
            ]),
            ownerStores: ["rooms-a": owner],
            controlStore: control
        )

        let page = try await store.readers(
            roomID: fixture.roomID,
            messageID: message,
            actorUserID: fixture.actorID,
            cursor: nil,
            pageSize: 1
        )

        #expect(page.readers == [V2ReadReceiptReader(
            userID: visible, publicIdentity: identity
        )])
        #expect(page.nextCursor == nil)
        #expect(await owner.candidateCallCount() == 2)
        #expect(await control.visibilityCallCount() == 2)
    }
}

private struct ReceiptFixture {
    let roomID = try! RoomID("00000000-0000-0000-0000-00000000e101")
    let actorID = try! UserID("00000000-0000-0000-0000-00000000e102")
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let command: V2RecordReadReceiptCommand
    let receipt: V2ReadReceipt

    init() throws {
        command = try .init(
            roomID: roomID,
            actorUserID: actorID,
            operationID: .init("00000000-0000-0000-0000-00000000e103"),
            readThroughRoomSequence: 19
        )
        receipt = .init(
            roomID: roomID,
            userID: actorID,
            readThroughRoomSequence: 19,
            recordedAt: now
        )
    }
}

private actor ReceiptRouter: V2RoomShardRouting {
    let routes: [RoomID: V2RoomShardRoute]

    init(routes: [RoomID: V2RoomShardRoute]) { self.routes = routes }

    func route(for roomID: RoomID) throws -> V2RoomShardRoute {
        guard let route = routes[roomID] else {
            throw V2RoomShardRouteError.roomNotFound
        }
        return route
    }
}

private actor GroupReceiptStoreSpy: V2GroupReadReceiptOwnerStore {
    let attempt: V2GroupReadReceiptRecordingAttempt
    private var recorded: [V2RecordReadReceiptCommand] = []
    private var candidatePages: [V2GroupReadReceiptReaderCandidatePage]
    private var candidateCalls = 0

    init(
        attempt: V2GroupReadReceiptRecordingAttempt,
        candidatePages: [V2GroupReadReceiptReaderCandidatePage] = []
    ) {
        self.attempt = attempt
        self.candidatePages = candidatePages
    }

    func recordGroup(
        command: V2RecordReadReceiptCommand,
        now _: Date
    ) -> V2GroupReadReceiptRecordingAttempt {
        recorded.append(command)
        return attempt
    }

    func commands() -> [V2RecordReadReceiptCommand] { recorded }

    func readerCandidates(
        roomID: RoomID,
        messageID: MessageID,
        actorUserID _: UserID,
        cursor _: String?,
        pageSize _: Int
    ) -> V2GroupReadReceiptReaderCandidatePage {
        candidateCalls += 1
        if !candidatePages.isEmpty { return candidatePages.removeFirst() }
        return .init(
            roomID: roomID,
            messageID: messageID,
            candidates: [],
            nextCursor: nil
        )
    }

    func candidateCallCount() -> Int { candidateCalls }
}

private actor RoutedReceiptControlSpy: V2ReadReceiptControlStore {
    let receipt: V2ReadReceipt
    private var recorded: [V2RecordReadReceiptCommand] = []
    private var preferences: [V2SetReadReceiptPreferencesCommand] = []
    private var readerCalls = 0
    private var visibilityCalls = 0
    private let visibleIdentities: [UserID: V2PublicIdentity]

    init(
        receipt: V2ReadReceipt,
        visibleIdentities: [UserID: V2PublicIdentity] = [:]
    ) {
        self.receipt = receipt
        self.visibleIdentities = visibleIdentities
    }

    func record(
        command: V2RecordReadReceiptCommand,
        now _: Date
    ) -> V2ReadReceiptOutcome {
        recorded.append(command)
        return .recorded(receipt)
    }

    func setPreferences(
        command: V2SetReadReceiptPreferencesCommand,
        now: Date
    ) -> V2SetReadReceiptPreferencesOutcome {
        preferences.append(command)
        return .updated(.init(
            allowsDirectReadReceipts: command.allowsDirectReadReceipts,
            allowsGroupReadReceipts: command.allowsGroupReadReceipts,
            updatedAt: now
        ))
    }

    func readers(
        roomID: RoomID,
        messageID: MessageID,
        actorUserID _: UserID,
        cursor _: String?,
        pageSize _: Int
    ) throws -> V2ReadReceiptReadersPage {
        readerCalls += 1
        return try .init(
            roomID: roomID,
            messageID: messageID,
            readers: [],
            nextCursor: nil
        )
    }

    func recordCommands() -> [V2RecordReadReceiptCommand] { recorded }
    func preferenceCommands() -> [V2SetReadReceiptPreferencesCommand] {
        preferences
    }
    func readerCallCount() -> Int { readerCalls }

    func visibleReaderIdentities(
        actorUserID _: UserID,
        candidateUserIDs: [UserID]
    ) -> [UserID: V2PublicIdentity] {
        visibilityCalls += 1
        return visibleIdentities.filter { candidateUserIDs.contains($0.key) }
    }

    func visibilityCallCount() -> Int { visibilityCalls }
}
