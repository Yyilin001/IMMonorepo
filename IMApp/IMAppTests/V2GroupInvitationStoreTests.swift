import Foundation
import Synchronization
@testable import IMV2ClientKit
import IMV2Core
import Testing
@testable import IMApp

@MainActor
@Suite("V2 group invitation intent isolation", .timeLimit(.minutes(1)))
struct V2GroupInvitationStoreTests {
    @Test("management retains transient content and clears terminal authentication failures", arguments: ["transient", "sessionInvalidated", "authorizationDenied"])
    func terminalAuthenticationClearsManagement(failure: String) async throws {
        let client = InvitationBarrierClient(), room = RoomID(uuid: UUID())
        let subject = V2GroupInvitationStore(client: client,operations:try fixtureOperations())
        await client.enableManagement()
        let load = Task { await subject.loadManagement(roomID: room.rawValue) }
        try await client.waitForManagement(1)
        let page = try managementPage(room, next: "next")
        await client.finishManagement(0, result: .success(page))
        await load.value
        let more = Task { await subject.loadMoreRequests(roomID: room.rawValue) }
        try await client.waitForManagement(2)
        #expect(subject.canManage)
        let terminal = failure != "transient"
        let error: any Error
        switch failure {
        case "authorizationDenied": error = V2ClientGroupInvitationError.authorizationDenied
        case "sessionInvalidated": error = V2AuthSessionError.sessionInvalidated
        default: error = V2HTTPFailure(kind: .transport, service: "accountAPI")
        }
        await client.finishManagement(1, result: .failure(error))
        await more.value
        #expect(subject.requests == (terminal ? [] : page.requests))
        #expect(subject.nextRequestCursor == (terminal ? nil : "next"))
        #expect(subject.feedback != nil)
        #expect(subject.canManage == !terminal)
        subject.endManagement()
    }

    @Test("management replacement drains prior reads and fences late results", arguments: [false, true], [false, true])
    func managementReplacement(sameRoom: Bool, succeeds: Bool) async throws {
        let client = InvitationBarrierClient()
        let subject = V2GroupInvitationStore(client: client,operations:try fixtureOperations())
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
        let subject = V2GroupInvitationStore(client: client,operations:try fixtureOperations())
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
        let subject = V2GroupInvitationStore(client: client,operations:try fixtureOperations())
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

    private func fixtureOperations(secrets: any V2InvitationSecretStoring = InvitationUnusedSecrets()) throws -> V2InvitationOperationService {
        let account=UserID(uuid:UUID()),binding=V2LocalInstallationBinding(value:UUID())
        let store=try GRDBV2LocalSyncStore(databaseURL:FileManager.default.temporaryDirectory.appending(path:"invite-page-\(UUID()).sqlite"),installationBinding:binding,userID:account)
        return .init(accountID:account,activationID:UUID(),store:store,client:InvitationOperationReadFixture(),secrets:secrets)
    }

    private func managementPage(_ room: RoomID, count: Int = 1, next: String? = nil) throws -> V2ClientGroupJoinRequestPage {
        .init(requests: try (0..<count).map { _ in
            try .init(requestID: .init(uuid: UUID()), inviteID: .init(uuid: UUID()), roomID: room,
                applicantUserID: .init(uuid: UUID()), note: nil, state: .pending,
                resumableDecisionOperationID: nil, createdAt: Date(), decidedAt: nil)
        }, nextCursor: next)
    }

    @Test("新邀请加载或失败时不能提交旧预览")
    func replacementFailureClearsSubmitCapability() async throws {
        let client = InvitationBarrierClient()
        let store = V2GroupInvitationStore(client: client,operations:try fixtureOperations())
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
        #expect(!store.canSubmit)
    }

    @Test("旧邀请迟到响应不能覆盖新预览")
    func latePreviewCannotReplaceNewInvitation() async throws {
        let client = InvitationBarrierClient()
        let secrets = InvitationRecordingSecrets()
        let store = V2GroupInvitationStore(client: client,operations:try fixtureOperations(secrets: secrets))
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
        await store.submit(note: "B note")
        #expect(secrets.authorizations.map(\.rawValue) == [b.rawValue])
    }

    @Test("无效链接立即清除旧预览")
    func malformedLinkClearsPreview() async throws {
        let client = InvitationBarrierClient()
        let store = V2GroupInvitationStore(client: client,operations:try fixtureOperations())
        let a = try secret("A")
        let open = Task { await store.open(a.rawValue) }
        await client.waitForPreview(a)
        await client.finishPreview(a, result: .success(try preview("A")))
        await open.value
        await store.open("invalid")
        await store.submit(note: nil)
        #expect(store.preview == nil)
        #expect(!store.canSubmit)
        #expect(!store.canSubmit)
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
    private var previews: [V2GroupInviteSecret: CheckedContinuation<V2GroupInvitePreview, any Error>] = [:]
    private var previewWaiters: [V2GroupInviteSecret: CheckedContinuation<Void, Never>] = [:]
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
    func activeInvites(roomID: RoomID) async throws -> [V2GroupInviteLink] { [] }
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
}

private struct InvitationOperationReadFixture:V2InvitationOperationClient {
    func baseline(roomID:RoomID) async throws -> V2GroupInvitationOperationBaseline {try .init(roomID:roomID,membershipRevision:0)}
    func admit(_ request:V2GroupInvitationAdmissionRequest) async throws -> V2GroupInvitationAdmissionResult {throw V2HTTPFailure(kind:.transport,service:"accountAPI")}
    func submit(_ submission:V2GroupInvitationSubmission) async throws -> V2GroupInvitationOperationRecoveryResult {throw V2HTTPFailure(kind:.transport,service:"accountAPI")}
    func recover(_ intent:V2GroupInvitationOperationIntent,action:V2OperationRecoveryRequest.Action) async throws -> V2GroupInvitationOperationRecoveryResult {.unresolved}
}
private struct InvitationUnusedSecrets:V2InvitationSecretStoring {
    func save(_ authorization:V2GroupInvitationSecretAuthorization,reference:UUID,accountID:UserID) throws {throw V2InvitationSecretStoreError.unavailable}
    func load(reference:UUID,accountID:UserID) throws -> V2GroupInvitationSecretAuthorization {throw V2InvitationSecretStoreError.missing}
    func remove(reference:UUID,accountID:UserID) throws {}
}

private final class InvitationRecordingSecrets: V2InvitationSecretStoring, Sendable {
    private let records = Mutex<[V2GroupInvitationSecretAuthorization]>([])
    var authorizations: [V2GroupInvitationSecretAuthorization] { records.withLock { $0 } }
    func save(_ authorization: V2GroupInvitationSecretAuthorization, reference: UUID, accountID: UserID) throws {
        records.withLock { $0.append(authorization) }
        throw V2InvitationSecretStoreError.unavailable
    }
    func load(reference: UUID, accountID: UserID) throws -> V2GroupInvitationSecretAuthorization { throw V2InvitationSecretStoreError.missing }
    func remove(reference: UUID, accountID: UserID) throws {}
}
