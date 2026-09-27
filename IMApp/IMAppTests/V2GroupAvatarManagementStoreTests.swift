import Foundation
import IMV2Core
import Synchronization
import Testing
@testable import IMV2ClientKit
@testable import IMApp

@MainActor
@Suite("Group avatar page state and dismissal", .timeLimit(.minutes(1)))
struct V2GroupAvatarManagementStoreTests {
    @Test func leaseAndCapabilityGateNewImagesWhileRemovalNeedsNoUpload() async throws {
        let clock = Mutex(ContinuousClock.now), room = RoomID(uuid: UUID())
        let manager = PageAvatarManager(snapshot: try snapshot(room: room, deadline: clock.withLock { $0 }.advanced(by: .seconds(60))))
        let stager = PageAvatarStager(), store = V2GroupAvatarManagementStore(roomID: room, manager: manager, stager: stager,
            notifier: nil, now: { clock.withLock { $0 } })
        await store.observe()
        #expect(store.canUpload && store.canRemove)
        let deadline = try #require(store.deadline)
        clock.withLock { $0 = $0.advanced(by: .seconds(61)) }
        store.expirePermission(deadline)
        #expect(!store.canUpload && !store.canRemove)
        store.importImage(from: URL(fileURLWithPath: "/unused.png"))
        #expect(await stager.staged == 0)
        await manager.update(try snapshot(room: room, deadline: clock.withLock { $0 }.advanced(by: .seconds(60)), upload: false))
        store.refresh(); await settle(store)
        #expect(!store.canUpload && store.canRemove)
        store.remove(); await settle(store)
        let changes = await manager.changes
        #expect(changes.count == 1 && changes.first?.revision == 7 && changes.first?.image == nil)
        store.suspend()
    }

    @Test func dismissalRejectsALatePermissionReply() async throws {
        let room = RoomID(uuid: UUID()), gate = AvatarPageGate()
        let manager = PageAvatarManager(snapshot: try snapshot(room: room), loadGate: gate)
        let store = V2GroupAvatarManagementStore(roomID: room, manager: manager, stager: PageAvatarStager(), notifier: nil)
        let observation = Task { await store.observe() }
        await gate.entered()
        store.suspend()
        await gate.release(); await observation.value
        guard case .inactive = store.state else { Issue.record("late reply reopened a closed page"); return }
        #expect(store.authority == nil && !store.canChange)
    }

    @Test("cancelled imports delete only drafts that never reached the journal boundary", arguments: [false, true])
    func stagedOwnership(afterHandoff: Bool) async throws {
        let room = RoomID(uuid: UUID()), gate = AvatarPageGate()
        let manager = PageAvatarManager(snapshot: try snapshot(room: room), changeGate: afterHandoff ? gate : nil)
        let stager = PageAvatarStager(gate: afterHandoff ? nil : gate)
        let store = V2GroupAvatarManagementStore(roomID: room, manager: manager, stager: stager, notifier: nil)
        await store.observe()
        store.importImage(from: URL(fileURLWithPath: "/selected.png"))
        await gate.entered()
        store.suspend(); await gate.release(); await settle(store)
        #expect(await stager.discarded == (afterHandoff ? 0 : 1))
        #expect(await manager.changes.count == (afterHandoff ? 1 : 0))
        #expect(store.snapshot == nil)
    }

    @Test func anUnknownOperationCanBeQueriedWithoutCurrentManagementPermission() async throws {
        let room = RoomID(uuid: UUID()), user = UserID(uuid: UUID())
        let command = try V2GroupAvatarCommand(operationID: .init(uuid: UUID()), roomID: room, expectedRevision: 0, mutation: .remove)
        let intent = V2GroupAvatarIntent(actorUserID: user, command: command, uploadJobID: nil, stage: .submitted,
            submissionStarted: true, recoveryAction: nil, closedDisposition: .awaitingDecision,
            attempts: 1, retryAt: Date(), issue: .outcomeUnknown, receipt: nil, closureProof: nil)
        let manager = PageAvatarManager(snapshot: .init(access: .forbidden, pending: [intent]))
        let store = V2GroupAvatarManagementStore(roomID: room, manager: manager, stager: PageAvatarStager(), notifier: nil)
        await store.observe()
        #expect(!store.canChange && !store.canReplace(intent))
        store.act(intent, action: .query); await settle(store)
        let actions = await manager.actions
        #expect(actions.count == 1 && actions.first?.id == command.operationID)
        guard case .query = actions.first?.action else { Issue.record("query was changed into another action"); return }
        store.suspend()
    }

    @Test func aFocusedOperationOutsideTheRoomPageIsShownAndActedOnByItsOriginalID() async throws {
        let room = RoomID(uuid: UUID()), actor = UserID(uuid: UUID())
        let intents = try (0..<17).map { _ -> V2GroupAvatarIntent in
            let command = try V2GroupAvatarCommand(operationID: .init(uuid: UUID()), roomID: room, expectedRevision: 0, mutation: .remove)
            return .init(actorUserID: actor, command: command, uploadJobID: nil, stage: .submitted,
                submissionStarted: true, recoveryAction: nil, closedDisposition: .awaitingDecision,
                attempts: 1, retryAt: Date(), issue: .outcomeUnknown, receipt: nil, closureProof: nil)
        }
        let focused = try #require(intents.last)
        let manager = PageAvatarManager(snapshot: .init(access: .forbidden, pending: Array(intents.prefix(16))), extraPending: focused)
        let store = V2GroupAvatarManagementStore(roomID: room, manager: manager, stager: PageAvatarStager(), notifier: nil,
            focusedOperationID: focused.id)
        await store.observe()
        #expect(store.pending.count == 16 && store.pending.first?.id == focused.id && store.didReadPending)
        store.act(focused, action: .closeIfAbsent); await settle(store)
        #expect(await manager.actions.first?.id == focused.id)
        #expect(!store.canUpload && !store.canRemove)
        store.suspend()
    }

    private func snapshot(room: RoomID, deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(60)),
                          upload: Bool = true) throws -> V2GroupAvatarManagementSnapshot {
        .init(access: .authorized(.init(state: try .init(roomID: room, mediaID: .init(uuid: UUID()), revision: 7),
            canManage: true, deadline: deadline, maximumUploadBytes: upload ? 1024 : nil)), pending: [])
    }
    private func settle(_ store: V2GroupAvatarManagementStore) async {
        while store.isPerformingAction { await Task.yield() }
    }
}

private actor AvatarPageGate {
    private let starts = AsyncStream<Void>.makeStream()
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0; starts.continuation.yield(()) } }
    func entered() async { var iterator = starts.stream.makeAsyncIterator(); _ = await iterator.next() }
    func release() { continuation?.resume(); continuation = nil }
}

private actor PageAvatarManager: V2GroupAvatarManaging {
    struct Change: Sendable { let revision: UInt64; let image: V2StagedConversationAttachment? }
    struct Action: Sendable { let id: GroupAvatarOperationID; let action: V2GroupAvatarManagementAction }
    var snapshot: V2GroupAvatarManagementSnapshot
    let loadGate: AvatarPageGate?, changeGate: AvatarPageGate?
    let extraPending: V2GroupAvatarIntent?
    private(set) var changes: [Change] = []
    private(set) var actions: [Action] = []
    init(snapshot: V2GroupAvatarManagementSnapshot, loadGate: AvatarPageGate? = nil, changeGate: AvatarPageGate? = nil,
         extraPending: V2GroupAvatarIntent? = nil) {
        self.snapshot = snapshot; self.loadGate = loadGate; self.changeGate = changeGate
        self.extraPending = extraPending
    }
    func update(_ snapshot: V2GroupAvatarManagementSnapshot) { self.snapshot = snapshot }
    func load(roomID: RoomID) async -> V2GroupAvatarManagementSnapshot { await loadGate?.wait(); return snapshot }
    func pending(roomID: RoomID) -> [V2GroupAvatarIntent] { snapshot.pending }
    func pendingIntent(roomID: RoomID, operationID: GroupAvatarOperationID) -> V2GroupAvatarIntent? {
        snapshot.pending.first { $0.id == operationID } ?? (extraPending?.id == operationID ? extraPending : nil)
    }
    func change(roomID: RoomID, expectedRevision: UInt64, image: V2StagedConversationAttachment?) async {
        changes.append(.init(revision: expectedRevision, image: image)); await changeGate?.wait()
    }
    func act(roomID: RoomID, operationID: GroupAvatarOperationID, action: V2GroupAvatarManagementAction) {
        actions.append(.init(id: operationID, action: action))
    }
}

private actor PageAvatarStager: V2ConversationAttachmentStaging {
    let gate: AvatarPageGate?
    private(set) var staged = 0, discarded = 0
    init(gate: AvatarPageGate? = nil) { self.gate = gate }
    func stageImportedFile(at sourceURL: URL) async -> V2StagedConversationAttachment {
        staged += 1; await gate?.wait()
        return .init(id: UUID(), fileURL: sourceURL, displayName: "image.png", contentType: "image/png", byteCount: 3)
    }
    func discard(_ attachment: V2StagedConversationAttachment) { discarded += 1 }
}
