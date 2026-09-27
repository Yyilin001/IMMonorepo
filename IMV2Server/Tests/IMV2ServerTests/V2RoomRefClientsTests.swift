import Foundation
import IMV2ActorContracts
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("RoomRef business clients")
struct V2RoomRefClientsTests {
    @Test("administration preserves actor, operation identity and typed failure")
    func administrationFailure() async throws {
        let room = RoomID(uuid: UUID()), actor = UserID(uuid: UUID()), target = UserID(uuid: UUID())
        let operation = try MembershipOperationID(UUID().uuidString)
        let request = V2AuthenticatedMembershipChange(roomID: room, actorUserID: actor,
            operationID: operation, targetUserID: target, action: .add,
            expectedMembershipRevision: 1)
        let caller = V2RoomRefUserCaller(timeout: .seconds(5)) { wire, principal, deadline in
            #expect(principal == actor && deadline > .now)
            guard case .administration(.membership(let value)) = wire else {
                Issue.record("wrong administration request"); throw V2RoomCallFailure.outcomeUnknown
            }
            #expect(value.roomID == room && value.operationID == operation && value.actorUserID == actor)
            return .administration(.failure(.membership(.actorNotOwner)))
        }
        let client = V2RoomRefAdministrationClient(caller: caller)
        await #expect(throws: V2RoomMembershipStoreError.actorNotOwner) {
            _ = try await client.change(request)
        }
    }

    @Test("an accepted write response for another room is outcome unknown")
    func administrationResultIdentity() async throws {
        let room = RoomID(uuid: UUID()), otherRoom = RoomID(uuid: UUID())
        let actor = UserID(uuid: UUID()), target = UserID(uuid: UUID())
        let request = V2AuthenticatedMembershipChange(roomID: room, actorUserID: actor,
            operationID: try .init(UUID().uuidString), targetUserID: target, action: .add,
            expectedMembershipRevision: 1)
        let result = V2ActorMembershipChangeResultWire(roomID: otherRoom, targetUserID: target,
            action: .add, membershipRevision: 2, roomSequence: 1,
            eventID: try .init(UUID().uuidString), createdAt: Date())
        let caller = V2RoomRefUserCaller(timeout: .seconds(5)) { _, _, _ in
            .administration(.membership(.changed(result)))
        }
        await #expect(throws: V2RoomCallFailure.outcomeUnknown) {
            _ = try await V2RoomRefAdministrationClient(caller: caller).change(request)
        }
    }

    @Test("a receipt domain refusal remains a typed refusal")
    func receiptFailure() async throws {
        let room = RoomID(uuid: UUID()), actor = UserID(uuid: UUID())
        let operation = try ReadReceiptOperationID(UUID().uuidString)
        let request = V2AuthenticatedReadReceipt(roomID: room, actorUserID: actor,
            operationID: operation, readThroughRoomSequence: 2)
        let caller = V2RoomRefUserCaller(timeout: .seconds(5)) { wire, principal, _ in
            #expect(principal == actor)
            guard case .receipt(.record(let value)) = wire else {
                Issue.record("wrong receipt request"); throw V2RoomCallFailure.outcomeUnknown
            }
            #expect(value.operationID == operation)
            return .receipt(.recordFailure(.store(.actorNotMember)))
        }
        let client = V2RoomRefQueryClient(caller: caller)
        await #expect(throws: V2ReadReceiptStoreError.actorNotMember) {
            _ = try await client.record(request)
        }
    }

    @Test("reader candidates are filtered by current control privacy and refill is bounded")
    func readerPrivacy() async throws {
        let room = RoomID(uuid: UUID()), message = MessageID(uuid: UUID())
        let actor = UserID(uuid: UUID()), hidden = UserID(uuid: UUID()), visible = UserID(uuid: UUID())
        let identity = try V2PublicIdentity(userID: visible, handle: .init("visible_reader"),
            displayName: "Visible Reader", accountKind: .regular)
        let control = ReaderPrivacyControl(visible: [visible: identity])
        let calls = CandidateCalls()
        let caller = V2RoomRefUserCaller(timeout: .seconds(5)) { request, principal, deadline in
            #expect(principal == actor && deadline > .now)
            guard case .receiptQuery(.readerCandidates(let query)) = request else {
                Issue.record("non-candidate receipt query"); throw V2ActorRoomReceiptWireError.invalidResult
            }
            await calls.add(query.cursor)
            let user = query.cursor == nil ? hidden : visible
            let next = query.cursor == nil ? "next-page" : nil
            return .receipt(.readerCandidates(.init(roomID: room, messageID: message,
                candidates: [.init(userID: user, readThroughRoomSequence: 2)], nextCursor: next)))
        }
        let client = V2RoomRefReadReceiptClient(rooms: .init(caller: caller), control: control)
        let page = try await client.readers(roomID: room, messageID: message,
            actorUserID: actor, cursor: nil, pageSize: 1)
        #expect(page.readers == [.init(userID: visible)])
        #expect(page.nextCursor == nil)
        #expect(await calls.values() == [nil, "next-page"])
        #expect(await control.visibilityCallCount() == 2)
        #expect(await control.ownerReadersCalled() == false)
    }

    @Test("reader refill stops at its candidate scan bound")
    func readerScanBound() async throws {
        let room = RoomID(uuid: UUID()), message = MessageID(uuid: UUID())
        let actor = UserID(uuid: UUID()), hidden = UserID(uuid: UUID())
        let calls = CandidateCalls()
        let caller = V2RoomRefUserCaller(timeout: .seconds(5)) { request, _, _ in
            guard case .receiptQuery(.readerCandidates(let query)) = request else {
                throw V2ActorRoomReceiptWireError.invalidResult
            }
            await calls.add(query.cursor)
            let index = (query.cursor.flatMap(Int.init) ?? 0) + 1
            return .receipt(.readerCandidates(.init(roomID: room, messageID: message,
                candidates: [.init(userID: hidden, readThroughRoomSequence: 2)],
                nextCursor: String(index))))
        }
        let client = V2RoomRefReadReceiptClient(rooms: .init(caller: caller),
            control: ReaderPrivacyControl(visible: [:]))
        let page = try await client.readers(roomID: room, messageID: message,
            actorUserID: actor, cursor: nil, pageSize: 1)
        #expect(page.readers.isEmpty && page.nextCursor == "100")
        #expect(await calls.values().count == 100)
    }

    @Test("recovery starts independent room turns concurrently and retains partial results")
    func recoveryPartialFailure() async throws {
        let first = RoomID(uuid: UUID()), second = RoomID(uuid: UUID())
        let actor = UserID(uuid: UUID())
        let barrier = ClientReadBarrier()
        let caller = V2RoomRefUserCaller(timeout: .seconds(5)) { request, principal, deadline in
            #expect(principal == actor && deadline > .now)
            guard case .recovery(let query) = request, query.kind == .state else {
                Issue.record("wrong recovery request"); throw V2ActorRoomRecoveryWireError.invalidResult
            }
            await barrier.enter()
            if query.roomID == first { return .recovery(.state(.unavailable)) }
            throw V2RoomCallFailure.notAccepted(.unavailable)
        }
        let client = V2RoomRefQueryClient(caller: caller, maximumConcurrentRooms: 2)
        let values = try await client.states(roomIDs: [first, second], actorUserID: actor)
        #expect(values[first] == .unavailable && values[second] == .retry)
        #expect(await barrier.peak() == 2)
    }

    @Test("recovery rejects a snapshot labeled as another room")
    func recoverySnapshotIdentity() async throws {
        let room = RoomID(uuid: UUID()), other = RoomID(uuid: UUID())
        let actor = UserID(uuid: UUID())
        let state = V2ActorRoomSynchronizationStateWire(roomID: other, ownerEpoch: 0,
            viewerMembershipRevision: 1, head: 1, trimmedThrough: 0,
            readThrough: 0, latestOwnMessageSequence: 0)
        let caller = V2RoomRefUserCaller(timeout: .seconds(5)) { _, _, _ in
            .recovery(.state(.state(state)))
        }
        await #expect(throws: V2ActorRoomRecoveryWireError.invalidResult) {
            _ = try await V2RoomRefQueryClient(caller: caller).states(roomIDs: [room], actorUserID: actor)
        }
    }

    @Test("nickname failure is typed and never falls through to contact alias storage")
    func profileFailure() async throws {
        let room = RoomID(uuid: UUID()), actor = UserID(uuid: UUID())
        let operation = try GroupNicknameOperationID(UUID().uuidString)
        let caller = V2RoomRefUserCaller(timeout: .seconds(5)) { request, principal, _ in
            #expect(principal == actor)
            guard case .administration(.groupNickname(let value)) = request else {
                Issue.record("wrong nickname request"); throw V2RoomCallFailure.outcomeUnknown
            }
            #expect(value.operationID == operation)
            return .administration(.failure(.profile(.forbidden)))
        }
        let client = V2RoomRefProfilePresentationClient(aliases: UnusedAliases(), caller: caller)
        await #expect(throws: V2ProfilePresentationError.forbidden) {
            _ = try await client.updateOwnGroupNickname(actorUserID: actor, roomID: room,
                operationID: operation, expectedRevision: nil, nickname: "member")
        }
    }

    @Test("contact alias enumeration stays on the user store")
    func contactAliasBoundary() async throws {
        let actor = UserID(uuid: UUID())
        let caller = V2RoomRefUserCaller(timeout: .seconds(5)) { _, _, _ in
            Issue.record("contact aliases entered a room turn")
            throw V2RoomCallFailure.outcomeUnknown
        }
        let client = V2RoomRefProfilePresentationClient(aliases: UnusedAliases(), caller: caller)
        let page = try await client.contactAliases(ownerUserID: actor, afterTargetUserID: nil, limit: 10)
        #expect(page.values.isEmpty && page.nextCursor == nil)
    }
}

private actor ClientReadBarrier {
    private var entered = 0
    private var maximum = 0
    private var waiter: CheckedContinuation<Void, Never>?
    func enter() async {
        entered += 1
        maximum = max(maximum, entered)
        if entered == 2 { waiter?.resume(); waiter = nil; return }
        // A watchdog releases a regressed serial caller instead of hanging a
        // test worker; the peak assertion still fails in that schedule.
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(2))
            release()
        }
        await withCheckedContinuation { waiter = $0 }
        watchdog.cancel()
    }
    private func release() { waiter?.resume(); waiter = nil }
    func peak() -> Int { maximum }
}

private actor CandidateCalls {
    private var cursors: [String?] = []
    func add(_ cursor: String?) { cursors.append(cursor) }
    func values() -> [String?] { cursors }
}

private actor ReaderPrivacyControl: V2ReadReceiptControlStore {
    private let visible: [UserID: V2PublicIdentity]
    private var visibilityCalls = 0
    private var ownerReadersCalls = 0

    init(visible: [UserID: V2PublicIdentity]) { self.visible = visible }

    func record(command: V2RecordReadReceiptCommand, now: Date) throws -> V2ReadReceiptOutcome {
        throw V2ReadReceiptStoreError.corruptPersistenceState
    }

    func setPreferences(command: V2SetReadReceiptPreferencesCommand,
                        now: Date) throws -> V2SetReadReceiptPreferencesOutcome {
        throw V2ReadReceiptStoreError.corruptPersistenceState
    }

    func readers(roomID: RoomID, messageID: MessageID, actorUserID: UserID,
                 cursor: String?, pageSize: Int) throws -> V2ReadReceiptReadersPage {
        ownerReadersCalls += 1
        throw V2ReadReceiptStoreError.corruptPersistenceState
    }

    func visibleReaderIdentities(actorUserID: UserID,
                                 candidateUserIDs: [UserID]) -> [UserID: V2PublicIdentity] {
        visibilityCalls += 1
        return visible.filter { candidateUserIDs.contains($0.key) }
    }

    func visibilityCallCount() -> Int { visibilityCalls }
    func ownerReadersCalled() -> Bool { ownerReadersCalls > 0 }
}

private struct UnusedAliases: V2ProfilePresentationManaging {
    func contactAliases(ownerUserID: UserID, afterTargetUserID: UserID?, limit: Int) async throws -> V2ContactAliasPage {
        .init(values: [], nextCursor: nil)
    }
    func updateContactAlias(ownerUserID: UserID, targetUserID: UserID,
                            operationID: ContactAliasOperationID, expectedRevision: V2ProfileRevision?,
                            remarkName: String?) async throws -> V2ContactAlias {
        throw V2ProfilePresentationError.corruptPersistenceState
    }
    func groupNicknames(actorUserID: UserID, roomID: RoomID,
                        afterUserID: UserID?, limit: Int) async throws -> V2GroupNicknamePage {
        throw V2ProfilePresentationError.corruptPersistenceState
    }
    func updateOwnGroupNickname(actorUserID: UserID, roomID: RoomID,
                                operationID: GroupNicknameOperationID, expectedRevision: V2ProfileRevision?,
                                nickname: String?) async throws -> V2GroupMemberPresentation {
        throw V2ProfilePresentationError.corruptPersistenceState
    }
}
