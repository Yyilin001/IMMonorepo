import Foundation
@testable import IMClientKit
import Testing
@testable import IMApp

@MainActor
struct ContactPresentationModelTests {
    private let currentUser = AuthUser(
        id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        email: "me@example.com"
    )

    private let peer = AuthUser(
        id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        email: "peer@example.com",
        displayName: "Peer"
    )

    @Test func contactOperationResultFactoriesSetToneAndSuccessState() {
        let success = ContactOperationResult.success("done")
        #expect(success.succeeded)
        #expect(success.tone == .success)
        #expect(success.message == "done")

        let failure = ContactOperationResult.failure("failed")
        #expect(failure.succeeded == false)
        #expect(failure.tone == .error)
        #expect(failure.message == "failed")

        let warning = ContactOperationResult.warning("wait")
        #expect(warning.succeeded == false)
        #expect(warning.tone == .warning)
        #expect(warning.message == "wait")
    }

    @Test func contactOperationErrorMapperReturnsStableMessages() {
        #expect(ContactOperationErrorMapper.message(for: APIError.timeout) == "当前网络不可用，请稍后重试。")
        #expect(ContactOperationErrorMapper.message(for: APIError.unauthorized(nil)) == "当前登录已失效，请重新登录。")
        #expect(ContactOperationErrorMapper.message(
            for: APIError.rateLimited(retryAfter: 12, message: "Too many requests")
        ) == "操作过于频繁，请在 12 秒后重试。")
        #expect(ContactOperationErrorMapper.message(
            for: APIError.validationFailed("好友申请不存在")
        ) == "该申请不存在或已被处理。")
        #expect(ContactOperationErrorMapper.message(
            for: APIError.validationFailed("contact already exists")
        ) == "对方已经是联系人或申请已存在。")
        #expect(ContactOperationErrorMapper.message(
            for: APIError.forbidden("user is blocked")
        ) == "当前关系状态不可操作，请刷新后重试。")
        #expect(ContactOperationErrorMapper.message(
            for: APIError.rateLimited(retryAfter: nil, message: "Too many requests")
        ) == "操作过于频繁，请稍后重试。")
        #expect(ContactOperationErrorMapper.message(
            for: APIError.server(statusCode: 503, message: "down")
        ) == "服务器暂时不可用，请稍后重试。")
    }

    @Test func contactRequestFormRejectsInvalidSelfExistingAndPendingEmails() {
        let contact = ContactResponseBody(
            id: peer.id,
            email: peer.email,
            displayName: "Peer",
            avatarPreset: nil,
            remark: "同事",
            createdAt: nil
        )
        let pending = contactRequest(
            id: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
            peer: AuthUser(
                id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                email: "pending@example.com"
            ),
            status: .pending,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        var form = ContactRequestFormModel(email: "bad-email")
        #expect(form.validation(
            currentUserEmail: currentUser.email,
            currentUserID: currentUser.id,
            contacts: [],
            requests: []
        ).message == "请输入有效的邮箱地址。")

        form.email = currentUser.email
        #expect(form.validation(
            currentUserEmail: currentUser.email,
            currentUserID: currentUser.id,
            contacts: [],
            requests: []
        ).message == "不能添加自己为好友。")

        form.email = peer.email
        #expect(form.validation(
            currentUserEmail: currentUser.email,
            currentUserID: currentUser.id,
            contacts: [contact],
            requests: []
        ).message == "该用户已经在通讯录中。")

        form.email = "pending@example.com"
        #expect(form.validation(
            currentUserEmail: currentUser.email,
            currentUserID: currentUser.id,
            contacts: [],
            requests: [pending],
            now: Date(timeIntervalSince1970: 1_800_000_100)
        ).message == "已有待处理的好友申请。")
    }

    @Test func expiredPendingRequestDoesNotBlockResendAndPresentationShowsExpired() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expiredRequest = contactRequest(
            id: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!,
            peer: peer,
            status: .pending,
            createdAt: now.addingTimeInterval(-ContactRequestPresentationState.expirationInterval - 60)
        )
        let form = ContactRequestFormModel(email: peer.email)

        #expect(form.validation(
            currentUserEmail: currentUser.email,
            currentUserID: currentUser.id,
            contacts: [],
            requests: [expiredRequest],
            now: now
        ).isValid)

        let presentation = ContactRequestPresentation(
            request: expiredRequest,
            currentUserID: currentUser.id,
            state: ContactRequestPresentationState.resolve(
                request: expiredRequest,
                currentUserID: currentUser.id,
                now: now
            )
        )
        #expect(presentation.state == .expired)
        #expect(presentation.subtitle.contains("重新发送"))
    }

    @Test func contactRequestClockDrivesExpiredPresentation() {
        let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        let request = contactRequest(
            id: UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!,
            peer: peer,
            status: .pending,
            createdAt: createdAt
        )
        let clock = ContactRequestClock(now: createdAt.addingTimeInterval(ContactRequestPresentationState.expirationInterval - 1))

        var state = ContactRequestPresentationState.resolve(
            request: request,
            currentUserID: currentUser.id,
            now: clock.now
        )
        #expect(state == .outgoingPending)

        clock.update(to: createdAt.addingTimeInterval(ContactRequestPresentationState.expirationInterval + 1))
        state = ContactRequestPresentationState.resolve(
            request: request,
            currentUserID: currentUser.id,
            now: clock.now
        )
        #expect(state == .expired)
    }

    @Test func contactRemarkFormTrimsAllowsEmptyAndRejectsLongValues() {
        var form = ContactRemarkFormModel(remark: "  项目同事  ")
        #expect(form.normalizedRemark == "项目同事")
        #expect(form.canSubmit)

        form.remark = "   "
        #expect(form.normalizedRemark.isEmpty)
        #expect(form.canSubmit)

        form.remark = String(repeating: "a", count: ContactRemarkFormModel.maxRemarkLength + 1)
        #expect(form.canSubmit == false)
        #expect(form.validationMessage == "备注不能超过 \(ContactRemarkFormModel.maxRemarkLength) 个字符。")
    }

    @Test func contactStoreSearchMatchesRemarkProfileDisplayNameAndEmail() {
        let store = ContactStore()
        store.contacts = [
            ContactResponseBody(
                id: peer.id,
                email: peer.email,
                displayName: "Profile Name",
                avatarPreset: nil,
                remark: "项目同事",
                createdAt: nil
            )
        ]

        #expect(store.filteredContacts(query: "项目").map(\.id) == [peer.id])
        #expect(store.filteredContacts(query: "Profile").map(\.id) == [peer.id])
        #expect(store.filteredContacts(query: "peer@").map(\.id) == [peer.id])
    }

    @Test func knownUserDisplayFallsBackToContactRequests() {
        let store = ContactStore()
        store.contactRequests = [
            contactRequest(
                id: UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!,
                peer: peer,
                status: .declined,
                createdAt: nil
            )
        ]

        let display = store.knownUserDisplay(for: peer.id)
        #expect(display?.displayName == peer.preferredDisplayName)
        #expect(display?.email == peer.email)
    }

    @Test func knownUserDisplayCacheSurvivesContactRemovalAndClearsOnSignOut() {
        let store = ContactStore()
        store.cacheKnownUserDisplay(KnownContactUserDisplay(
            id: peer.id,
            displayName: "Cached Peer",
            email: peer.email,
            avatarPreset: nil
        ))

        #expect(store.knownUserDisplay(for: peer.id)?.displayName == "Cached Peer")

        store.resetForSignedOut()

        #expect(store.knownUserDisplay(for: peer.id) == nil)
    }

    @Test func contactRequestResendDraftPreservesRetryPayload() {
        let requestID = UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")!
        let draft = ContactRequestResendDraft(
            sourceRequestID: requestID,
            email: "peer@example.com",
            message: "hello",
            remark: "同事"
        )

        #expect(draft.id == requestID)
        #expect(draft.email == "peer@example.com")
        #expect(draft.message == "hello")
        #expect(draft.remark == "同事")
    }

    @Test func contactRequestResendRecoveryStateTracksRetryDraft() {
        let draft = ContactRequestResendDraft(
            sourceRequestID: UUID(uuidString: "ffffffff-eeee-eeee-eeee-eeeeeeeeeeee")!,
            email: "peer@example.com",
            message: "hello",
            remark: "同事"
        )

        var state = ContactRequestResendRecoveryState.waitingForRetry(draft)
        #expect(state == .waitingForRetry(draft))

        state = .retrying(draft)
        #expect(state == .retrying(draft))

        state = .idle
        #expect(state == .idle)
    }

    @Test func contactTaskBagPreventsDuplicateKeysAndAllowsIndependentKeys() async throws {
        let taskBag = ContactTaskBag()
        var startedKeys: [ContactViewTaskKey] = []

        let didStartSend = taskBag.run(.sendRequest) {
            startedKeys.append(.sendRequest)
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(didStartSend)
        let didStartDuplicateSend = taskBag.run(.sendRequest) {
            startedKeys.append(.sendRequest)
        }
        #expect(didStartDuplicateSend == false)
        let didStartRefresh = taskBag.run(.refresh("contacts")) {
            startedKeys.append(.refresh("contacts"))
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(didStartRefresh)

        await Task.yield()

        #expect(startedKeys == [.sendRequest, .refresh("contacts")])
        #expect(taskBag.isRunning(.sendRequest))
        #expect(taskBag.isRunning(.refresh("contacts")))

        taskBag.cancelAll()

        #expect(taskBag.isRunning(.sendRequest) == false)
        #expect(taskBag.isRunning(.refresh("contacts")) == false)
    }

    @Test func contactTaskBagCancelledTaskDoesNotClearReplacementTask() async throws {
        let taskBag = ContactTaskBag()

        let didStartFirst = taskBag.run(.sendRequest) {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(didStartFirst)
        taskBag.cancel(.sendRequest)

        let didStartSecond = taskBag.run(.sendRequest) {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(didStartSecond)

        try await Task.sleep(nanoseconds: 40_000_000)

        #expect(taskBag.isRunning(.sendRequest))

        taskBag.cancelAll()
        #expect(taskBag.isRunning(.sendRequest) == false)
    }

    private func contactRequest(
        id: UUID,
        peer: AuthUser,
        status: ContactRequestStatus,
        createdAt: Date?
    ) -> ContactRequestResponseBody {
        ContactRequestResponseBody(
            id: id,
            requester: currentUser,
            addressee: peer,
            status: status,
            message: "hi",
            requesterRemark: "备注",
            addresseeRemark: nil,
            createdAt: createdAt,
            updatedAt: createdAt,
            respondedAt: status == .pending ? nil : createdAt
        )
    }
}
