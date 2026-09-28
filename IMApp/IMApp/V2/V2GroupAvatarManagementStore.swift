import Foundation
import IMV2ClientKit
import IMV2Core
import Observation

@MainActor
@Observable
final class V2GroupAvatarManagementStore {
    enum State { case inactive, loading, loaded(V2GroupAvatarManagementSnapshot) }
    private(set) var state: State = .inactive
    private(set) var feedback: String?
    private(set) var isPerformingAction = false
    private(set) var didReadPending = false
    private(set) var isStale = false
    private(set) var presentationInvalidationGeneration: UInt64 = 0
    let roomID: RoomID
    let focusedOperationID: GroupAvatarOperationID?
    private let manager: any V2GroupAvatarManaging
    private let stager: any V2ConversationAttachmentStaging
    private let notifier: V2ProjectionChangeNotifier?
    private let now: @Sendable () -> ContinuousClock.Instant
    private var activation: UUID?
    private var authorityRead: UUID?
    private var pendingRead: UUID?
    private var actionTask: Task<Void, Never>?

    init(roomID: RoomID, manager: any V2GroupAvatarManaging, stager: any V2ConversationAttachmentStaging,
         notifier: V2ProjectionChangeNotifier?, focusedOperationID: GroupAvatarOperationID? = nil,
         now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.roomID = roomID; self.manager = manager; self.stager = stager; self.notifier = notifier; self.now = now
        self.focusedOperationID = focusedOperationID
    }

    var snapshot: V2GroupAvatarManagementSnapshot? { if case .loaded(let value) = state { value } else { nil } }
    var pending: [V2GroupAvatarIntent] { snapshot?.pending ?? [] }
    var displayAuthority: V2GroupAvatarManagementSnapshot.Authority? {
        guard case .authorized(let value) = snapshot?.access, value.deadline > now(), activation != nil else { return nil }
        return value
    }
    var authority: V2GroupAvatarManagementSnapshot.Authority? {
        guard !isStale else { return nil }
        return displayAuthority
    }
    var deadline: ContinuousClock.Instant? {
        guard case .authorized(let value) = snapshot?.access else { return nil }
        return value.deadline
    }
    var canChange: Bool { !isPerformingAction && pending.isEmpty && authority?.canManage == true }
    var canUpload: Bool { canChange && authority?.maximumUploadBytes != nil }
    var canRemove: Bool { canChange && authority?.state.mediaID != nil }

    /// The view owns these subscriptions. Two fixed streams keep permission
    /// invalidations separate from frequent local claim/progress transactions.
    func observe() async {
        let epoch = UUID()
        activation = epoch; state = .loading; feedback = nil; didReadPending = false
        guard let notifier else { await reload(epoch: epoch); return }
        async let permissions: Void = observePermissions(notifier, epoch: epoch)
        async let intents: Void = observePending(notifier, epoch: epoch)
        _ = await (permissions, intents)
        if activation == epoch { suspend() }
    }

    func suspend() {
        activation = nil; authorityRead = nil; pendingRead = nil
        actionTask?.cancel()
        state = .inactive; feedback = nil; didReadPending = false; isStale = false
    }

    func expirePermission(_ deadline: ContinuousClock.Instant) {
        guard self.deadline == deadline, deadline <= now(), let snapshot else { return }
        presentationInvalidationGeneration &+= 1
        state = .loaded(.init(access: .unavailable, pending: snapshot.pending))
    }

    func refresh() {
        startAction { epoch in await self.reload(epoch: epoch) }
    }

    func importImage(from url: URL) {
        guard canUpload, let expected = authority?.state.revision else { return }
        startAction { epoch in
            let image = try await self.stager.stageImportedFile(at: url)
            do {
                try Task.checkCancellation()
                guard self.activation == epoch else { throw CancellationError() }
            } catch {
                // Still exclusively a page draft; no journal call has begun.
                await self.stager.discard(image)
                throw error
            }
            // After handoff, even cancellation may race a committed journal
            // transaction. Referenced files survive; aged unclaimed drafts use
            // the account's bounded orphan cleanup on next activation.
            try await self.manager.change(roomID: self.roomID, expectedRevision: expected, image: image)
            await self.reload(epoch: epoch)
        }
    }

    func remove() {
        guard canRemove, let expected = authority?.state.revision else { return }
        startAction { epoch in
            try await self.manager.change(roomID: self.roomID, expectedRevision: expected, image: nil)
            await self.reload(epoch: epoch)
        }
    }

    func act(_ intent: V2GroupAvatarIntent, action: V2GroupAvatarManagementAction) {
        startAction { epoch in
            try await self.manager.act(roomID: self.roomID, operationID: intent.id, action: action)
            await self.reload(epoch: epoch)
        }
    }

    func canReplace(_ intent: V2GroupAvatarIntent) -> Bool {
        guard intent.stage == .closed, intent.closedDisposition == .awaitingDecision,
              !isPerformingAction, let authority, authority.canManage else { return false }
        return intent.uploadJobID == nil || authority.maximumUploadBytes != nil
    }

    func replace(_ intent: V2GroupAvatarIntent) {
        guard canReplace(intent), let revision = authority?.state.revision else { return }
        act(intent, action: .replace(expectedRevision: revision))
    }

    private func startAction(_ operation: @escaping @MainActor (UUID) async throws -> Void) {
        guard let epoch = activation, actionTask == nil else { return }
        isPerformingAction = true; feedback = nil
        // One page-owned waiter. Account services retain and recover any frozen
        // mutation; dismiss/background cancels this waiter and suppresses UI.
        actionTask = Task {
            defer { actionTask = nil; isPerformingAction = false }
            do {
                try Task.checkCancellation()
                guard activation == epoch else { throw CancellationError() }
                try await operation(epoch)
            }
            catch is CancellationError { }
            catch {
                guard activation == epoch, !Task.isCancelled else { return }
                feedback = Self.message(for: error)
                await reloadPending(epoch: epoch)
            }
        }
    }

    private func observePermissions(_ notifier: V2ProjectionChangeNotifier, epoch: UUID) async {
        for await _ in await notifier.updates(scopes: .presentations) {
            guard activation == epoch, !Task.isCancelled else { return }
            await reload(epoch: epoch, authorizationChanged: true)
        }
    }

    private func observePending(_ notifier: V2ProjectionChangeNotifier, epoch: UUID) async {
        for await _ in await notifier.updates(scopes: .conversationDetails) {
            guard activation == epoch, !Task.isCancelled else { return }
            await reloadPending(epoch: epoch)
        }
    }

    private func reload(epoch: UUID, authorizationChanged: Bool = false) async {
        guard activation == epoch, !Task.isCancelled else { return }
        let read = UUID(), pendingAtStart = pendingRead
        authorityRead = read
        isStale = true
        if authorizationChanged { presentationInvalidationGeneration &+= 1 }
        if authorizationChanged || displayAuthority == nil {
            state = .loaded(.init(access: .unavailable, pending: pending))
        }
        do {
            let value = try await manager.load(roomID: roomID)
            let values = try await includingFocus(value.pending)
            guard activation == epoch, authorityRead == read, !Task.isCancelled else { return }
            didReadPending = true; isStale = false
            if case .forbidden = value.access { presentationInvalidationGeneration &+= 1 }
            state = .loaded(.init(access: value.access, pending: pendingAtStart == pendingRead ? values : pending))
        } catch is CancellationError { }
        catch {
            guard activation == epoch, authorityRead == read, !Task.isCancelled else { return }
            if Self.revokesAccess(error) { presentationInvalidationGeneration &+= 1 }
            if Self.revokesAccess(error) || displayAuthority == nil {
                state = .loaded(.init(access: Self.revokesAccess(error) ? .forbidden : .unavailable, pending: pending))
            }
            feedback = Self.message(for: error)
            await reloadPending(epoch: epoch)
        }
    }

    private static func revokesAccess(_ error: Error) -> Bool {
        if let error = error as? V2AuthSessionError {
            return error != .credentialsUnavailable
        }
        if let error = error as? V2HTTPFailure { return error.statusCode == 403 }
        return (error as? V2GroupAvatarReadError) == .forbidden
            || (error as? V2GroupAvatarManagementError) == .forbidden
    }

    private func reloadPending(epoch: UUID) async {
        guard activation == epoch, !Task.isCancelled else { return }
        let read = UUID(); pendingRead = read
        do {
            let values = try await includingFocus(manager.pending(roomID: roomID))
            guard activation == epoch, pendingRead == read, !Task.isCancelled else { return }
            didReadPending = true
            let completed = !pending.isEmpty && values.isEmpty
            state = .loaded(.init(access: snapshot?.access ?? .unavailable, pending: values))
            // A command receipt can arrive before room-log catch-up. Refresh the
            // current avatar once when that local operation leaves the queue.
            if completed { await reload(epoch: epoch) }
        } catch is CancellationError { }
        catch {
            guard activation == epoch, pendingRead == read, !Task.isCancelled else { return }
            feedback = "无法读取更改记录，请刷新后重试。"
        }
    }

    private func includingFocus(_ values: [V2GroupAvatarIntent]) async throws -> [V2GroupAvatarIntent] {
        try Task.checkCancellation()
        guard let focusedOperationID else { return values }
        let focused: V2GroupAvatarIntent?
        if let cached = values.first(where: { $0.id == focusedOperationID }) { focused = cached }
        else { focused = try await manager.pendingIntent(roomID: roomID, operationID: focusedOperationID) }
        guard let focused else { return values }
        return [focused] + values.filter { $0.id != focusedOperationID }.prefix(15)
    }

    static func message(for error: any Error) -> String {
        switch error {
        case V2GroupAvatarManagementError.forbidden, V2GroupAvatarReadError.forbidden:
            "当前无法管理群头像。已有更改仍可确认结果。"
        case V2GroupAvatarManagementError.revisionChanged:
            "群头像已被更新，请刷新后再决定是否更改。"
        case V2GroupAvatarManagementError.pendingDecision:
            "请先处理已有的头像更改。"
        case V2GroupAvatarManagementError.imageUnsupported:
            "请选择 JPEG 或 PNG 图片。"
        case V2GroupAvatarManagementError.imageTooLarge:
            "图片超过当前大小限制，请选择较小的图片。"
        case V2ConversationAttachmentStagingError.stagingQuotaExceeded:
            "待处理的附件占用较多空间，请先处理已有更改。"
        default:
            "暂时无法完成操作。已保存的更改会继续确认，请勿重复创建。"
        }
    }
}
