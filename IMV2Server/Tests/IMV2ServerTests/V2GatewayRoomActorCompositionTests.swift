import Foundation
import IMV2ActorContracts
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("Gateway RoomRef composition")
struct V2GatewayRoomActorCompositionTests {
    @Test("event log pull and subscription use only the room capability; prepared pull falls back to a page")
    func eventLogBoundary() async throws {
        let room = RoomID(uuid: UUID()), user = UserID(uuid: UUID())
        let calls = GatewayRoomCalls()
        let page = try V2GroupEventLogPage(roomID: room, events: [],
            nextRoomSequence: 7, hasMore: false)
        let subscription = try V2GroupEventSubscription(roomID: room,
            highWatermark: 7, membershipRevision: 4)
        let caller = V2RoomRefUserCaller(timeout: .seconds(5)) { request, principal, deadline in
            #expect(principal == user && deadline > .now)
            switch request {
            case .roomLog(.pull(let query)):
                #expect(query.roomID == room && query.afterRoomSequence == 7)
                await calls.add("pull")
                return .roomLog(.page(try .init(page)))
            case .roomLog(.subscribe(let query)):
                #expect(query.roomID == room)
                await calls.add("subscribe")
                return .roomLog(.subscription(try .init(subscription)))
            default:
                Issue.record("event log escaped its room capability")
                throw V2RoomCallFailure.outcomeUnknown
            }
        }
        let client = V2RoomRefGroupEventLogClient(rooms: .init(caller: caller))
        #expect(try await client.pull(roomID: room, actorUserID: user,
            afterRoomSequence: 7, pageSize: 10) == page)
        #expect(try await client.subscribe(roomID: room, actorUserID: user) == subscription)
        let context = V2PreparedGroupEventPageEncodingContext(requestID: 1,
            frameVersion: 21, compression: nil, maximumUncompressedPayloadBytes: 65_536,
            compressionThresholdBytes: 1_024, maximumExpansionRatio: 64,
            maximumGroupEventPagePayloadBytes: 60_000,
            cache: .init(configuration: .init(maximumEntries: 1,
                maximumBytes: 65_536, shardCount: 1)))
        guard case .page(let fallback) = try await client.pullPrepared(roomID: room,
            actorUserID: user, afterRoomSequence: 7, pageSize: 10,
            context: context) else {
            Issue.record("prepared path skipped ordinary RoomRef page"); return
        }
        #expect(fallback == page)
        #expect(await calls.values() == ["pull", "subscribe", "pull"])
    }

    @Test("pre-room creation uses coordinator while preferences remain control-owned")
    func creationBoundary() async throws {
        let actor = UserID(uuid: UUID()), target = UserID(uuid: UUID())
        let room = RoomID(uuid: UUID()), directOperation = try DirectRoomOperationID(UUID().uuidString)
        let groupOperation = try GroupRoomOperationID(UUID().uuidString)
        let permissions = GatewayDirectPreferences()
        let calls = GatewayRoomCalls()
        let now = Date()
        let services = V2GatewayRoomCreationServices(directPreferences: permissions,
            callTimeout: try .init(5_000)) { command, deadline in
            #expect(deadline > .now)
            switch command {
            case .openDirect(let request):
                #expect(request.actorUserID == actor && request.targetUserID == target)
                await calls.add("open")
                return .direct(.opened(.init(roomID: room, actorUserID: actor,
                    targetUserID: target, createdAt: now)))
            case .beginStaged(let request):
                #expect(request.operationID == groupOperation)
                await calls.add("begin")
                return .draft(.init(operationID: groupOperation, title: request.title,
                    stagedMemberCount: 0))
            case .appendStaged(let request):
                #expect(request.memberUserIDs == [target])
                await calls.add("append")
                return .draft(.init(operationID: groupOperation, title: "Group",
                    stagedMemberCount: 1))
            case .finalizeStaged:
                await calls.add("finalize")
                return .group(.idempotencyConflict)
            case .cancelStaged:
                await calls.add("cancel")
                return .cancelled
            case .createGroup:
                Issue.record("unexpected direct group create"); throw V2RoomCallFailure.outcomeUnknown
            }
        }
        let opened = try await services.direct.open(actorUserID: actor,
            operationID: directOperation, targetUserID: target)
        #expect(opened == .opened(.init(roomID: room, actorUserID: actor,
            targetUserID: target, createdAt: now)))
        let preferenceID = try StrangerMessagePreferenceOperationID(UUID().uuidString)
        _ = try await services.direct.setStrangerMessagePermission(actorUserID: actor,
            operationID: preferenceID, permission: .allow)
        #expect(await permissions.calls() == 1)
        #expect(try await services.staged.begin(actorUserID: actor,
            operationID: groupOperation, title: "Group").stagedMemberCount == 0)
        #expect(try await services.staged.append(actorUserID: actor,
            operationID: groupOperation, memberUserIDs: [target]).stagedMemberCount == 1)
        #expect(try await services.staged.finalize(actorUserID: actor,
            operationID: groupOperation) == .idempotencyConflict)
        try await services.staged.cancel(actorUserID: actor, operationID: groupOperation)
        #expect(await calls.values() == ["open", "begin", "append", "finalize", "cancel"])
    }

    @Test("a mismatched creation result is unknown, never accepted")
    func creationResponseIdentity() async throws {
        let actor = UserID(uuid: UUID()), target = UserID(uuid: UUID())
        let operation = try DirectRoomOperationID(UUID().uuidString)
        let services = V2GatewayRoomCreationServices(directPreferences: GatewayDirectPreferences(),
            callTimeout: try .init(5_000)) { _, _ in
            .direct(.opened(.init(roomID: .init(uuid: UUID()), actorUserID: target,
                targetUserID: actor, createdAt: Date())))
        }
        await #expect(throws: V2RoomCallFailure.outcomeUnknown) {
            _ = try await services.direct.open(actorUserID: actor,
                operationID: operation, targetUserID: target)
        }
    }
}

private actor GatewayRoomCalls {
    private var recorded: [String] = []
    func add(_ value: String) { recorded.append(value) }
    func values() -> [String] { recorded }
}

private actor GatewayDirectPreferences: V2DirectMessagePreferenceManaging {
    private var count = 0
    func calls() -> Int { count }

    func setStrangerMessagePermission(actorUserID: UserID,
        operationID: StrangerMessagePreferenceOperationID,
        permission: V2StrangerMessagePermission) -> V2SetStrangerMessagePermissionOutcome {
        count += 1
        return .updated(permission: permission, updatedAt: Date())
    }

    func setUserAddPermission(actorUserID: UserID,
        operationID: UserAddPreferenceOperationID,
        permission: V2UserAddPermission) -> V2SetUserAddPermissionOutcome {
        count += 1
        return .updated(permission: permission, updatedAt: Date())
    }
}
