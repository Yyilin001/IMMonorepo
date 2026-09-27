import Foundation
import IMV2ClientKit
import IMV2Core
import Testing
@testable import IMApp

@MainActor
@Suite("V2 group invitation intent isolation", .timeLimit(.minutes(1)))
struct V2GroupInvitationStoreTests {
    @Test("management replacement drains prior reads and fences late results", arguments: [false, true], [false, true])
    func managementReplacement(sameRoom: Bool, succeeds: Bool) async throws {
        let client = InvitationBarrierClient()
        let subject = V2GroupInvitationStore(client: client)
        await client.enableManagement()
        let room = RoomID(uuid: UUID()), nextRoom = sameRoom ? room : RoomID(uuid: UUID())
        let first = Task { await subject.loadManagement(roomID: room.rawValue) }
        try await client.waitForManagement(1)
        let second = Task { await subject.loadManagement(roomID: nextRoom.rawValue) }
        try await Task.sleep(for: .milliseconds(10))
        #expect(await client.managementCalls.count == 1)
        await client.finishManagement(0, result: succeeds ? .success(try managementPage(room)) : .failure(V2ClientGroupInvitationError.authorizationDenied))
        await first.value
        try await client.waitForManagement(2)
        #expect(subject.requests.isEmpty && subject.feedback == nil && subject.isWorking)
        let expected = try managementPage(nextRoom)
        await client.finishManagement(1, result: .success(expected))
        await second.value
        #expect(subject.requests == expected.requests && subject.feedback == nil && !subject.isWorking)
        subject.endManagement()
    }

    @Test("closing management or signing out clears its data and ignores late errors", arguments: [false, true])
    func closedManagement(invalidate: Bool) async throws {
        let client = InvitationBarrierClient(), room = RoomID(uuid: UUID())
        let subject = V2GroupInvitationStore(client: client)
        await client.enableManagement()
        let first = Task { await subject.loadManagement(roomID: room.rawValue) }
        try await client.waitForManagement(1)
        await client.finishManagement(0, result: .success(try managementPage(room, next: "page-2")))
        await first.value
        #expect(!subject.requests.isEmpty)
        let more = Task { await subject.loadMoreRequests(roomID: room.rawValue) }
        try await client.waitForManagement(2)
        if invalidate { subject.invalidate() } else { subject.endManagement() }
        #expect(subject.requests.isEmpty && subject.nextRequestCursor == nil)
        await client.finishManagement(1, result: .failure(V2ClientGroupInvitationError.authorizationDenied))
        await more.value
        #expect(subject.feedback == nil && subject.requests.isEmpty && !subject.isWorking)
    }

    @Test("management pagination keeps a bounded window and can restart at the beginning")
    func managementWindow() async throws {
        let client = InvitationBarrierClient(), room = RoomID(uuid: UUID())
        let subject = V2GroupInvitationStore(client: client)
        await client.enableManagement()
        for index in 0..<11 {
            let load = Task {
                if index == 0 { await subject.loadManagement(roomID: room.rawValue) }
                else { await subject.loadMoreRequests(roomID: room.rawValue) }
            }
            try await client.waitForManagement(index + 1)
            await client.finishManagement(index, result: .success(try managementPage(room, count: 100, next: "page-\(index + 1)")))
            await load.value
            #expect(subject.requests.count == min(1_000, (index + 1) * 100))
        }
        #expect(subject.hasEarlierRequests)
        let restart = Task { await subject.loadManagement(roomID: room.rawValue) }
        try await client.waitForManagement(12)
        #expect(await client.managementCalls.last?.cursor == nil)
        let firstPage = try managementPage(room)
        await client.finishManagement(11, result: .success(firstPage))
        await restart.value
        #expect(!subject.hasEarlierRequests && subject.requests == firstPage.requests)
        subject.endManagement()
    }

    private func managementPage(_ room: RoomID, count: Int = 1, next: String? = nil) throws -> V2ClientGroupJoinRequestPage {
        .init(requests: try (0..<count).map { _ in
            try .init(requestID: .init(uuid: UUID()), inviteID: .init(uuid: UUID()), roomID: room,
                applicantUserID: .init(uuid: UUID()), note: nil, state: .pending,
                resumableDecisionOperationID: nil, createdAt: Date(), decidedAt: nil)
        }, nextCursor: next)
    }

    @Test("提交 A 后切到 B，A 的迟到完成不能改变 B 的加载、预览或提交", arguments: [0, 1, 2], [false, true])
    func lateSubmissionCannotChangeReplacement(stage: Int, succeeds: Bool) async throws {
        let client = InvitationBarrierClient()
        let store = V2GroupInvitationStore(client: client)
        let a = try secret("A"), b = try secret("B")
        let previewA = try preview("A"), previewB = try preview("B")
        let openingA = Task { await store.open(a.rawValue) }
        await client.waitForPreview(a)
        await client.finishPreview(a, result: .success(previewA))
        await openingA.value
        let submittingA = Task { await store.submit(note: "A note") }
        await client.waitForSubmission(1)
        let openingB = Task { await store.open(b.rawValue) }
        await client.waitForPreview(b)
        var submittingB: Task<Void, Never>?
        if stage > 0 {
            await client.finishPreview(b, result: .success(previewB))
            await openingB.value
            if stage == 2 {
                submittingB = Task { await store.submit(note: "B note") }
                await client.waitForSubmission(2)
            }
        }
        await client.finishSubmission(index: 0, result: succeeds ? .success(.alreadyMember(previewA)) : .failure(V2ClientGroupInvitationError.networkFailure))
        await submittingA.value
        #expect(store.isPresentingJoin)
        #expect(store.joinFeedback == nil)
        #expect(store.isJoining == (stage != 1))
        #expect(store.canSubmit == (stage == 1))
        #expect(store.preview == (stage == 0 ? nil : previewB))
        if stage == 0 {
            await client.finishPreview(b, result: .success(previewB))
            await openingB.value
        }
        if submittingB == nil {
            submittingB = Task { await store.submit(note: "B note") }
            await client.waitForSubmission(2)
        }
        let sent = await client.submissions
        #expect(sent.map(\.secret) == [a, b])
        #expect(sent.map(\.note) == ["A note", "B note"])
        #expect(sent[0].operationID != sent[1].operationID)
        await client.finishSubmission(index: 1, result: .success(.alreadyMember(previewB)))
        await submittingB?.value
        #expect(store.preview == previewB)
        #expect(!store.isJoining && !store.canSubmit)
        #expect(store.joinFeedback == "你已经是该群成员。")
    }

    @Test("新邀请加载或失败时不能提交旧预览")
    func replacementFailureClearsSubmitCapability() async throws {
        let client = InvitationBarrierClient()
        let store = V2GroupInvitationStore(client: client)
        let a = try secret("A"), b = try secret("B")
        let first = Task { await store.open(a.rawValue) }
        await client.waitForPreview(a)
        await client.finishPreview(a, result: .success(try preview("A")))
        await first.value
        #expect(store.canSubmit)
        let second = Task { await store.open(b.rawValue) }
        await client.waitForPreview(b)
        #expect(store.preview == nil)
        #expect(!store.canSubmit)
        await store.submit(note: nil)
        await client.finishPreview(b, result: .failure(V2ClientGroupInvitationError.unavailable))
        await second.value
        await store.submit(note: nil)
        #expect(store.preview == nil)
        #expect(await client.submissions.isEmpty)
    }

    @Test("旧邀请迟到响应不能覆盖新预览")
    func latePreviewCannotReplaceNewInvitation() async throws {
        let client = InvitationBarrierClient()
        let store = V2GroupInvitationStore(client: client)
        let a = try secret("A"), b = try secret("B")
        let first = Task { await store.open(a.rawValue) }
        await client.waitForPreview(a)
        let second = Task { await store.open(b.rawValue) }
        await client.waitForPreview(b)
        let expected = try preview("B")
        await client.finishPreview(b, result: .success(expected))
        await second.value
        await client.finishPreview(a, result: .success(try preview("A")))
        await first.value
        #expect(store.preview == expected)
        let submit = Task { await store.submit(note: "B note") }
        await client.waitForSubmission(1)
        let sent = try #require(await client.submissions.first)
        #expect(sent.secret == b)
        await client.finishSubmission(result: .failure(V2ClientGroupInvitationError.networkFailure))
        await submit.value
    }

    @Test("不确定提交复用相同意图 ID，修改备注分配新 ID")
    func retryIdentityIsBoundToExactIntent() async throws {
        let client = InvitationBarrierClient()
        let store = V2GroupInvitationStore(client: client)
        let a = try secret("A")
        let open = Task { await store.open(a.rawValue) }
        await client.waitForPreview(a)
        await client.finishPreview(a, result: .success(try preview("A")))
        await open.value
        for (index, note) in ["first", "first", "changed"].enumerated() {
            let submit = Task { await store.submit(note: note) }
            await client.waitForSubmission(index + 1)
            await store.submit(note: "duplicate while in flight")
            await client.finishSubmission(result: .failure(V2ClientGroupInvitationError.networkFailure))
            await submit.value
            #expect(store.canSubmit)
        }
        let sent = await client.submissions
        #expect(sent.count == 3)
        #expect(sent[0].operationID == sent[1].operationID)
        #expect(sent[1].operationID != sent[2].operationID)
    }

    @Test("关闭或退出后忽略提交的迟到成功", arguments: [false, true])
    func closedScopeRejectsLateSubmission(invalidate: Bool) async throws {
        let client = InvitationBarrierClient()
        let store = V2GroupInvitationStore(client: client)
        let a = try secret("A")
        let open = Task { await store.open(a.rawValue) }
        await client.waitForPreview(a)
        let value = try preview("A")
        await client.finishPreview(a, result: .success(value))
        await open.value
        let submit = Task { await store.submit(note: nil) }
        await client.waitForSubmission(1)
        if invalidate { store.invalidate() } else { store.dismissJoin() }
        await client.finishSubmission(result: .success(.alreadyMember(value)))
        await submit.value
        #expect(store.preview == nil)
        #expect(!store.canSubmit)
        #expect(!store.isPresentingJoin)
        #expect(store.joinFeedback == nil)
        if invalidate {
            await store.open(a.rawValue)
            #expect(!store.isPresentingJoin)
        }
    }

    @Test("无效链接立即清除旧预览")
    func malformedLinkClearsPreview() async throws {
        let client = InvitationBarrierClient()
        let store = V2GroupInvitationStore(client: client)
        let a = try secret("A")
        let open = Task { await store.open(a.rawValue) }
        await client.waitForPreview(a)
        await client.finishPreview(a, result: .success(try preview("A")))
        await open.value
        await store.open("invalid")
        await store.submit(note: nil)
        #expect(store.preview == nil)
        #expect(!store.canSubmit)
        #expect(await client.submissions.isEmpty)
    }

    @Test("取消后可重新申请，重试使用同一申请身份", arguments: ["cancelled", "approved", "rejected", "retry"])
    func cancellationResult(_ scenario: String) async throws {
        let client = InvitationBarrierClient()
        // Each store owns exactly the client whose delayed responses it consumes.
        let subject = V2GroupInvitationStore(client: client)
        let secret = try secret("A"), base = try preview("A"), id = GroupJoinRequestID(uuid: UUID())
        let pending = try V2GroupInvitePreview(inviteID: base.inviteID, roomID: base.roomID, roomTitle: base.roomTitle, expiresAt: base.expiresAt, requestState: .pending, requestID: id, isAlreadyMember: false)
        let open = Task { await subject.open(secret.rawValue) }
        await client.waitForPreview(secret)
        await client.finishPreview(secret, result: .success(pending))
        await open.value
        #expect(subject.canCancelRequest && !subject.canSubmit)
        let cancel = Task { await subject.cancelRequest() }
        await client.waitForCancellation(1)
        #expect(subject.isJoining && !subject.canCancelRequest)
        await subject.cancelRequest()
        #expect(await client.cancellations.count == 1)
        let state: V2GroupJoinRequestState = scenario == "retry" ? .cancelled : try #require(.init(rawValue: scenario))
        let result = try cancellationRecord(pending, state: state)
        await client.finishCancellation(result: scenario == "retry" ? .failure(V2ClientGroupInvitationError.networkFailure) : .success(result))
        await cancel.value
        if scenario == "retry" {
            #expect(subject.canCancelRequest && subject.preview == pending)
            let retry = Task { await subject.cancelRequest() }
            await client.waitForCancellation(2)
            #expect(await client.cancellations == [id, id])
            await client.finishCancellation(result: .success(result))
            await retry.value
        }
        #expect(subject.preview?.requestState == state)
        #expect(subject.canSubmit == (state == .cancelled))
        #expect(!subject.canCancelRequest && !subject.isJoining)
    }

    @Test("迟到取消结果不能覆盖新邀请、关闭页面或退出后的状态", arguments: ["replace", "dismiss", "invalidate"])
    func lateCancellation(_ scenario: String) async throws {
        let client = InvitationBarrierClient()
        let subject = V2GroupInvitationStore(client: client)
        let secret = try secret("A"), base = try preview("A")
        let pending = try V2GroupInvitePreview(inviteID: base.inviteID, roomID: base.roomID, roomTitle: base.roomTitle, expiresAt: base.expiresAt, requestState: .pending, requestID: .init(uuid: UUID()), isAlreadyMember: false)
        let open = Task { await subject.open(secret.rawValue) }
        await client.waitForPreview(secret)
        await client.finishPreview(secret, result: .success(pending))
        await open.value
        let cancel = Task { await subject.cancelRequest() }
        await client.waitForCancellation(1)
        let replacement = try preview("B")
        if scenario == "replace" {
            let b = try self.secret("B")
            let next = Task { await subject.open(b.rawValue) }
            await client.waitForPreview(b)
            await client.finishPreview(b, result: .success(replacement))
            await next.value
        } else if scenario == "dismiss" { subject.dismissJoin() }
        else { subject.invalidate() }
        await client.finishCancellation(result: .success(try cancellationRecord(pending, state: .cancelled)))
        await cancel.value
        #expect(subject.preview == (scenario == "replace" ? replacement : nil))
        #expect(subject.joinFeedback == nil && !subject.isJoining)
        #expect(subject.canSubmit == (scenario == "replace"))
    }

    private func cancellationRecord(_ preview: V2GroupInvitePreview, state: V2GroupJoinRequestState) throws -> V2ClientGroupJoinRequest {
        try .init(requestID: #require(preview.requestID), inviteID: preview.inviteID, roomID: preview.roomID,
                  applicantUserID: .init(uuid: UUID()),
                  note: nil, state: state, resumableDecisionOperationID: nil, createdAt: Date(), decidedAt: Date())
    }

    private func secret(_ character: String) throws -> V2GroupInviteSecret {
        try .init(String(repeating: character, count: 43))
    }
    private func preview(_ title: String) throws -> V2GroupInvitePreview {
        try .init(inviteID: .init(uuid: UUID()), roomID: .init(uuid: UUID()), roomTitle: title,
                  expiresAt: Date().addingTimeInterval(3600), requestState: nil, requestID: nil, isAlreadyMember: false)
    }
}

// Intentionally ignores task cancellation to exercise late network completion.
private actor InvitationBarrierClient: V2ClientGroupInvitationManaging {
    struct Submission: Sendable {
        let secret: V2GroupInviteSecret
        let operationID: GroupJoinRequestOperationID
        let note: String?
    }
    private(set) var submissions: [Submission] = []
    private var previews: [V2GroupInviteSecret: CheckedContinuation<V2GroupInvitePreview, any Error>] = [:]
    private var previewWaiters: [V2GroupInviteSecret: CheckedContinuation<Void, Never>] = [:]
    private var pendingSubmissions: [Int: CheckedContinuation<V2ClientGroupJoinSubmissionOutcome, any Error>] = [:]
    private var submissionWaiter: CheckedContinuation<Void, Never>?
    func preview(secret: V2GroupInviteSecret) async throws -> V2GroupInvitePreview {
        try await withCheckedThrowingContinuation {
            previews[secret] = $0
            previewWaiters.removeValue(forKey: secret)?.resume()
        }
    }
    func waitForPreview(_ secret: V2GroupInviteSecret) async {
        guard previews[secret] == nil else { return }
        await withCheckedContinuation { previewWaiters[secret] = $0 }
    }
    func finishPreview(_ secret: V2GroupInviteSecret, result: Result<V2GroupInvitePreview, any Error>) {
        previews.removeValue(forKey: secret)?.resume(with: result)
    }
    func submit(secret: V2GroupInviteSecret, operationID: GroupJoinRequestOperationID, note: String?) async throws -> V2ClientGroupJoinSubmissionOutcome {
        let index = submissions.count
        submissions.append(.init(secret: secret, operationID: operationID, note: note))
        return try await withCheckedThrowingContinuation {
            pendingSubmissions[index] = $0
            submissionWaiter?.resume()
            submissionWaiter = nil
        }
    }
    func waitForSubmission(_ count: Int) async {
        guard submissions.count < count else { return }
        await withCheckedContinuation { submissionWaiter = $0 }
    }
    func finishSubmission(index: Int? = nil, result: Result<V2ClientGroupJoinSubmissionOutcome, any Error>) {
        pendingSubmissions.removeValue(forKey: index ?? (submissions.count - 1))?.resume(with: result)
    }
    func create(roomID: RoomID, operationID: GroupInviteOperationID, lifetimeSeconds: Int, maximumApprovedUses: Int) async throws -> V2GroupInviteLink { throw V2ClientGroupInvitationError.unavailable }
    func activeInvites(roomID: RoomID) async throws -> [V2GroupInviteLink] { [] }
    func revoke(inviteID: GroupInviteID, roomID: RoomID, operationID: GroupInviteOperationID) async throws {}
    private var controlledManagement = false
    private(set) var managementCalls: [(room: RoomID, cursor: String?)] = []
    private var managementPages: [Int: CheckedContinuation<V2ClientGroupJoinRequestPage, any Error>] = [:]
    func enableManagement() { controlledManagement = true }
    func pendingRequests(roomID: RoomID, cursor: String?, pageSize: Int) async throws -> V2ClientGroupJoinRequestPage {
        guard controlledManagement else { return .init(requests: [], nextCursor: nil) }
        let index = managementCalls.count
        managementCalls.append((roomID, cursor))
        return try await withCheckedThrowingContinuation { managementPages[index] = $0 }
    }
    func waitForManagement(_ count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while managementCalls.count < count {
            guard ContinuousClock.now < deadline else { throw V2ClientGroupInvitationError.networkFailure }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    func finishManagement(_ index: Int, result: Result<V2ClientGroupJoinRequestPage, any Error>) {
        managementPages.removeValue(forKey: index)?.resume(with: result)
    }
    private(set) var cancellations: [GroupJoinRequestID] = []
    private var pendingCancellation: CheckedContinuation<V2ClientGroupJoinRequest, any Error>?
    private var cancellationWaiter: CheckedContinuation<Void, Never>?
    func cancel(roomID: RoomID, requestID: GroupJoinRequestID) async throws -> V2ClientGroupJoinRequest {
        cancellations.append(requestID)
        return try await withCheckedThrowingContinuation {
            pendingCancellation = $0
            cancellationWaiter?.resume()
            cancellationWaiter = nil
        }
    }
    func waitForCancellation(_ count: Int) async {
        guard cancellations.count < count else { return }
        await withCheckedContinuation { cancellationWaiter = $0 }
    }
    func finishCancellation(result: Result<V2ClientGroupJoinRequest, any Error>) {
        pendingCancellation?.resume(with: result)
        pendingCancellation = nil
    }
    func decide(roomID: RoomID, requestID: GroupJoinRequestID, operationID: GroupJoinDecisionOperationID, decision: V2GroupJoinDecision) async throws -> V2ClientGroupJoinDecisionOutcome { throw V2ClientGroupInvitationError.unavailable }
}
