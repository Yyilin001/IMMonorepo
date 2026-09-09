import Foundation
import IMV2ClientKit
import IMV2Core
import Testing
@testable import IMApp

@MainActor
@Suite("V2 group invitation intent isolation", .timeLimit(.minutes(1)))
struct V2GroupInvitationStoreTests {
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
    func pendingRequests(roomID: RoomID, cursor: String?, pageSize: Int) async throws -> V2GroupJoinRequestPage { .init(requests: [], nextCursor: nil) }
    func decide(roomID: RoomID, requestID: GroupJoinRequestID, operationID: GroupJoinDecisionOperationID, decision: V2GroupJoinDecision) async throws -> V2ClientGroupJoinDecisionOutcome { throw V2ClientGroupInvitationError.unavailable }
}
