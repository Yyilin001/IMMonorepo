import CoreImage.CIFilterBuiltins
import IMV2ClientKit
import IMV2Core
import Observation
import SwiftUI
import UIKit
import Vision
import VisionKit

/// 群邀请管理与入群申请的界面状态容器。
///
/// 它同时承载「管理端」的邀请列表/待处理申请，以及「申请人端」的扫码预览与提交状态；
/// 每个操作标识都会在本地缓存以复用，使重试保持幂等。
@MainActor
@Observable
final class V2GroupInvitationStore {
    private let client: any V2ClientGroupInvitationManaging
    private let operations:V2InvitationOperationService
    private(set) var pending:[V2InvitationPending]=[]
    private var managementBaseline:V2GroupInvitationOperationBaseline?
    private var baselineDeadline:ContinuousClock.Instant?
    private(set) var links: [V2GroupInviteLink] = []
    private(set) var requests: [V2ClientGroupJoinRequest] = []
    private(set) var nextRequestCursor: String?
    private(set) var hasEarlierRequests = false
    private var managementRoomID: RoomID?
    private var managementGeneration = UUID()
    private var managementTask: Task<Void, Error>?
    /// 已成功预览、可以与提交动作配对的邀请。
    ///
    /// 令牌只有先经过一次成功且匹配的预览，才可能进入提交阶段。
    private struct PreviewedInvitation {
        let secret: V2GroupInviteSecret
        let preview: V2GroupInvitePreview
    }
    private enum JoinState {
        case idle
        case loading
        case ready(PreviewedInvitation)
        case submitting(PreviewedInvitation)
        case cancelling(PreviewedInvitation)
        case retryable(PreviewedInvitation, String)
        case completed(PreviewedInvitation, String)
        case failed(String)
    }
    private var joinState: JoinState = .idle
    @ObservationIgnored private var joinGeneration = UUID()
    @ObservationIgnored private var previewTask: Task<V2GroupInvitePreview, any Error>?
    @ObservationIgnored private var isInvalidated = false

    private var previewedInvitation: PreviewedInvitation? {
        switch joinState {
        case .ready(let value), .submitting(let value), .cancelling(let value), .retryable(let value, _), .completed(let value, _): value
        case .idle, .loading, .failed: nil
        }
    }
    /// 当前预览到的邀请信息；未处于可预览状态时为 `nil`。
    var preview: V2GroupInvitePreview? { previewedInvitation?.preview }
    /// 当前是否处于预览加载或提交过程中。
    var isJoining: Bool {
        switch joinState { case .loading, .submitting, .cancelling: true; default: false }
    }
    /// 当前是否可以提交入群申请。
    ///
    /// 仅无申请或已取消的邀请允许提交；已失效、已是成员或正在处理时返回 `false`。
    var canSubmit: Bool {
        guard !isInvalidated, !pending.contains(where: { $0.intent.roomID == previewedInvitation?.preview.roomID && $0.preparationState != .cancelled && $0.work?.scheduling != .finished }) else { return false }
        switch joinState {
        case .ready(let value), .retryable(let value, _):
            return !value.preview.isAlreadyMember && (value.preview.requestState == nil || value.preview.requestState == .cancelled)
        case .completed(let value, _):
            return !value.preview.isAlreadyMember && value.preview.requestState == .cancelled
        default: return false
        }
    }
    var canCancelRequest: Bool {
        !isInvalidated && !isJoining && preview?.requestState == .pending && !pending.contains(where: {$0.intent.roomID == preview?.roomID && $0.work?.scheduling != .finished})
    }
    /// 面向用户的加入流程反馈文案；无反馈时为 `nil`。
    var joinFeedback: String? {
        switch joinState {
        case .failed(let message), .retryable(_, let message), .completed(_, let message): message
        default: nil
        }
    }
    private(set) var feedback: String?
    private(set) var isWorking = false
    var isPresentingJoin = false
    var isPresentingScanner = false

    init(client: any V2ClientGroupInvitationManaging,operations:V2InvitationOperationService) { self.client = client;self.operations=operations }

    var canManage:Bool {!isInvalidated && managementRoomID != nil && managementBaseline != nil && (baselineDeadline.map {$0 > .now} ?? false)}
    func observePending(roomID:String) async {
        guard let room=try? RoomID(roomID) else {return}
        do {
            for try await value in await operations.updates(roomID:room) {
                try Task.checkCancellation()
                guard !isInvalidated else {return}
                let prior=Set(pending.compactMap {$0.work?.scheduling == .finished ? $0.work?.id:nil})
                let completed=value.contains {$0.work?.scheduling == .finished && !prior.contains($0.work!.id)}
                pending=value
                if completed,managementRoomID==room {await loadManagement(roomID:room.rawValue)}
                if completed,let invitation=previewedInvitation,invitation.preview.roomID==room {
                    let generation=joinGeneration
                    do {
                        let updated=try await client.preview(secret:invitation.secret)
                        try Task.checkCancellation()
                        guard generation==joinGeneration,!isInvalidated,updated.inviteID==invitation.preview.inviteID,updated.roomID==room else {continue}
                        joinState = .completed(.init(secret:invitation.secret,preview:updated),"已收到原操作结果，申请状态已更新。")
                    } catch is CancellationError {throw CancellationError()}
                    catch {guard generation==joinGeneration,!isInvalidated else {continue};joinState = .retryable(invitation,"原操作已有结果，当前邀请状态暂无法读取。")}
                }
            }
        }
        catch is CancellationError {}
        catch {feedback="本地邀请任务读取暂停。"}
    }
    func resume(_ value:V2InvitationPending) async {
        guard !isInvalidated else {return}
        do {if value.work != nil {try await operations.resume(id:value.id)} else {try await operations.closeOriginal(id:value.id)}}
        catch {feedback="原操作核对暂不可用。"}
    }
    func discard(_ value:V2InvitationPending) async {guard !isInvalidated else {return};do {try await operations.discard(id:value.id)} catch {feedback="无法移除草稿。"}}
    func reconfirm(_ value:V2InvitationPending) async {
        guard !isInvalidated else {return}
        do {
            let action:V2GroupInvitationOperationAction
            switch value.intent.action {
            case .create(let life,let uses,_):guard canManage,let baseline=managementBaseline else {throw V2InvitationPreparationError.confirmationRequired};action = .create(lifetimeSeconds:life,maximumApprovedUses:uses,expectedMembershipRevision:baseline.membershipRevision)
            case .revoke(let invite,_):guard canManage,let baseline=managementBaseline else {throw V2InvitationPreparationError.confirmationRequired};action = .revoke(inviteID:invite,expectedMembershipRevision:baseline.membershipRevision)
            case .decide(let request,let decision,_):guard canManage,let baseline=managementBaseline else {throw V2InvitationPreparationError.confirmationRequired};action = .decide(requestID:request,decision:decision,expectedMembershipRevision:baseline.membershipRevision)
            default:action=value.intent.action
            }
            let confirmation=try await operations.confirmation(roomID:value.intent.roomID,action:action)
            _ = try await operations.reconfirm(id:value.id,confirmation:confirmation)
            feedback="已明确重新确认原提案。"
        } catch {feedback="请刷新管理版本后重新确认。"}
    }

    /// 加载该房间的邀请列表与待处理入群申请。
    ///
    /// - Parameter roomID: 目标群组房间标识。
    func loadManagement(roomID: String) async {
        guard let room = try? RoomID(roomID) else { feedback = "群聊标识无效。"; return }
        guard !isInvalidated else { return }
        if managementRoomID != room {
            endManagement()
            managementRoomID = room
        }
        // A refresh owns a new publication generation even within the same room.
        // Await cancellation without allowing the old wrapper to publish its error.
        managementGeneration = UUID()
        let generation = managementGeneration
        if let prior = managementTask {
            prior.cancel()
            _ = await prior.result
        }
        guard generation == managementGeneration, !isInvalidated, !Task.isCancelled else { return }
        await perform { [self] in try await refreshManagement(room: room) }
    }

    func endManagement() {
        managementGeneration = UUID()
        managementRoomID = nil
        managementBaseline=nil;baselineDeadline=nil
        managementTask?.cancel()
        links = []; requests = []; nextRequestCursor = nil; hasEarlierRequests = false; feedback = nil
    }

    /// 创建一条群邀请。
    ///
    /// - Parameters:
    ///   - roomID: 目标群组房间标识。
    ///   - lifetimeSeconds: 邀请有效期秒数，默认 7 天。
    ///   - maximumUses: 最多可被批准使用的次数，默认 100。
    func create(roomID: String, lifetimeSeconds: Int = 7 * 86_400, maximumUses: Int = 100) async {
        guard let room = try? RoomID(roomID) else { feedback = "群聊标识无效。"; return }
        guard managementRoomID == room else { return }
        guard canManage,let baseline=managementBaseline else {feedback="请先刷新管理权限与成员版本。";return}
        await perform { [self] in
            let confirmation=try await operations.confirmation(roomID:room,action:.create(lifetimeSeconds:UInt64(lifetimeSeconds),maximumApprovedUses:maximumUses,expectedMembershipRevision:baseline.membershipRevision))
            _ = try await operations.enqueue(confirmation);feedback="邀请创建意图已保存，等待权威结果。"
        }
    }

    /// 撤销一条群邀请。
    ///
    /// - Parameter link: 待撤销的邀请链接。
    func revoke(_ link: V2GroupInviteLink) async {
        guard managementRoomID == link.roomID else { return }
        guard canManage,let baseline=managementBaseline else {feedback="请先刷新管理权限与成员版本。";return}
        await perform { [self] in
            let confirmation=try await operations.confirmation(roomID:link.roomID,action:.revoke(inviteID:link.inviteID,expectedMembershipRevision:baseline.membershipRevision))
            _ = try await operations.enqueue(confirmation);feedback="撤销意图已保存，等待权威结果。"
        }
    }

    /// 批准或拒绝一条入群申请。
    ///
    /// - Parameters:
    ///   - request: 待处理的入群申请。
    ///   - decision: 批准或拒绝。
    func decide(_ request: V2ClientGroupJoinRequest, decision: V2GroupJoinDecision) async {
        guard managementRoomID == request.roomID, requests.contains(where: { $0.requestID == request.requestID }) else { return }
        guard canManage,let baseline=managementBaseline else {feedback="请先刷新管理权限与成员版本。";return}
        await perform { [self] in
            if let operation=request.resumableDecisionOperationID?.uuidValue,let original=pending.first(where: {$0.intent.identity.operation.rawOperationID==operation.uuidString}) {try await operations.resume(id:original.id);return}
            guard request.resumableDecisionOperationID == nil else {feedback="缺少原审批意图，请刷新原操作状态；不会另建审批身份。";return}
            let confirmation=try await operations.confirmation(roomID:request.roomID,action:.decide(requestID:request.requestID,decision:decision,expectedMembershipRevision:baseline.membershipRevision),operationID:UUID())
            _ = try await operations.enqueue(confirmation);feedback="审批意图已保存，等待权威结果。"
        }
    }

    /// 按游标继续读取待处理入群申请。
    ///
    /// - Parameter roomID: 目标群组房间标识。
    func loadMoreRequests(roomID: String) async {
        guard let room = try? RoomID(roomID), managementRoomID == room, let cursor = nextRequestCursor else { return }
        let generation = managementGeneration
        await perform { [self] in
            let page = try await client.pendingRequests(roomID: room, cursor: cursor, pageSize: 100)
            try Task.checkCancellation()
            guard managementGeneration == generation, managementRoomID == room else { return }
            try validate(page, room: room, cursor: cursor)
            let existing = Set(requests.map(\.requestID))
            requests.append(contentsOf: page.requests.filter { !existing.contains($0.requestID) })
            if requests.count > 1_000 {
                requests.removeFirst(requests.count - 1_000)
                hasEarlierRequests = true
            }
            nextRequestCursor = page.nextCursor
        }
    }

    /// 解析用户提供的邀请链接或二维码内容并进入预览流程。
    ///
    /// 只有预览成功且回传的秘密值与输入匹配时，后续才允许提交。
    ///
    /// - Parameter value: 邀请链接或扫码得到的原始文本。
    func open(_ value: String) async {
        guard !isInvalidated else { return }
        let secret = Self.secret(from: value)
        // Reopening the same ready invitation is a no-op. A different or
        // invalid token always removes the old submit capability first.
        if let secret, secret == previewedInvitation?.secret, !isJoining { return }
        cancelJoinWork()
        let generation = joinGeneration
        isPresentingJoin = true
        guard let secret else {
            joinState = .failed("邀请链接或二维码无效。")
            return
        }
        joinState = .loading
        let client = client
        // Store-owned work can be cancelled by a new link, dismissal or logout.
        let task = Task { try await client.preview(secret: secret) }
        previewTask = task
        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard generation == joinGeneration, !isInvalidated else { return }
            previewTask = nil
            joinState = .ready(.init(secret: secret, preview: result))
        } catch {
            guard generation == joinGeneration, !isInvalidated else { return }
            previewTask = nil
            joinState = error is CancellationError ? .idle : .failed(Self.errorMessage(error))
        }
    }

    /// 提交入群申请。
    ///
    /// - Parameter note: 可选的申请附言。
    func submit(note: String?) async {
        guard canSubmit, let invitation = previewedInvitation else { return }
        let generation=joinGeneration
        joinState = .submitting(invitation)
        do {
            let authorization=V2GroupInvitationSecretAuthorization(secret:invitation.secret)
            let confirmation=try await operations.confirmation(roomID:invitation.preview.roomID,action:.submit(inviteID:invitation.preview.inviteID,tokenDigest:authorization.tokenDigest,note:note))
            _ = try await operations.enqueue(confirmation,authorization:authorization)
            guard generation==joinGeneration,!isInvalidated else {return}
            joinState = .completed(invitation,"申请意图已安全保存，等待原操作结果。")
        } catch {
            guard generation==joinGeneration,!isInvalidated else {return}
            joinState = .retryable(invitation,Self.errorMessage(error))
        }
    }

    func cancelRequest() async {
        guard canCancelRequest,let invitation=previewedInvitation,let request=invitation.preview.requestID else {return}
        let generation=joinGeneration;joinState = .cancelling(invitation)
        do {
            let confirmation=try await operations.confirmation(roomID:invitation.preview.roomID,action:.cancel(requestID:request))
            _ = try await operations.enqueue(confirmation)
            guard generation==joinGeneration,!isInvalidated else {return}
            joinState = .completed(invitation,"取消意图已保存，等待权威结果。")
        } catch {guard generation==joinGeneration,!isInvalidated else {return};joinState = .retryable(invitation,Self.errorMessage(error))}
    }

    /// 结束当前加入流程并清空预览状态。
    func dismissJoin() {
        cancelJoinWork()
        isPresentingJoin = false
        isPresentingScanner = false
        joinState = .idle
    }

    /// 使整个容器失效；失效后不再接受新的提交动作。
    func invalidate() {
        isInvalidated = true
        endManagement()
        dismissJoin()
    }

    private func cancelJoinWork() {
        joinGeneration = UUID()
        previewTask?.cancel()
        previewTask = nil
    }

    static func inviteURL(for secret: V2GroupInviteSecret) -> URL {
        var components = URLComponents(); components.scheme = "iim"; components.host = "group-invite"; components.queryItems = [.init(name: "token", value: secret.rawValue)]
        return components.url!
    }

    private static func secret(from value: String) -> V2GroupInviteSecret? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct = try? V2GroupInviteSecret(trimmed) { return direct }
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "iim", url.host == "group-invite",
              let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "token" })?.value
        else { return nil }
        return try? .init(token)
    }

    private static func updatedPreview(_ current: V2GroupInvitePreview, request: V2ClientGroupJoinRequest) throws -> V2GroupInvitePreview {
        guard request.inviteID == current.inviteID, request.roomID == current.roomID else {
            throw V2ClientGroupInvitationError.invalidResponse
        }
        return try .init(
            inviteID: current.inviteID, roomID: current.roomID, roomTitle: current.roomTitle,
            expiresAt: current.expiresAt, requestState: request.state,
            requestID: request.requestID, isAlreadyMember: false
        )
    }
    private static func errorMessage(_ error: any Error) -> String {
        guard let error = error as? V2ClientGroupInvitationError else {
            return "邀请服务暂不可用，请检查网络后重试。"
        }
        return switch error {
        case .authorizationDenied: "没有管理该群邀请的权限。"
        case .unavailable: "邀请不存在、已撤销、已过期或次数已用完。"
        case .memberLimitReached: "群成员已达上限。"
        case .rateLimited: "操作过于频繁，请稍后重试。"
        case .conflict: "状态已变化，请刷新后重试。"
        default: "邀请服务暂不可用，请检查网络后重试。"
        }
    }
    private func refreshManagement(room: RoomID) async throws {
        try Task.checkCancellation()
        guard managementRoomID == room else { return }
        let generation = managementGeneration
        managementBaseline=nil;baselineDeadline=nil
        async let baseline = operations.baseline(roomID:room)
        async let refreshedLinks = client.activeInvites(roomID: room)
        async let refreshedRequests = client.pendingRequests(roomID: room, cursor: nil, pageSize: 100)
        let (newLinks, requestPage, authority) = try await (refreshedLinks, refreshedRequests, baseline)
        try Task.checkCancellation()
        guard generation == managementGeneration, managementRoomID == room, !isInvalidated else { return }
        guard newLinks.count <= 100, newLinks.allSatisfy({ $0.roomID == room }),
              Set(newLinks.map(\.inviteID)).count == newLinks.count else { throw V2ClientGroupInvitationError.invalidResponse }
        try validate(requestPage, room: room, cursor: nil)
        managementBaseline=authority;baselineDeadline = .now.advanced(by:.seconds(30))
        links = newLinks
        requests = requestPage.requests
        nextRequestCursor = requestPage.nextCursor
        hasEarlierRequests = false
        feedback = nil
    }
    private func validate(_ page: V2ClientGroupJoinRequestPage, room: RoomID, cursor: String?) throws {
        guard page.requests.count <= 100, Set(page.requests.map(\.requestID)).count == page.requests.count,
              page.requests.allSatisfy({ $0.roomID == room && $0.state == .pending }),
              page.nextCursor == nil || (page.nextCursor != cursor && page.nextCursor?.isEmpty == false && page.nextCursor!.utf8.count <= 1_024)
        else { throw V2ClientGroupInvitationError.invalidResponse }
    }
    private func perform(_ body: @escaping @MainActor () async throws -> Void) async {
        guard !isWorking, !isInvalidated else { return }
        let generation = managementGeneration
        isWorking = true
        let task = Task {
            defer { isWorking = false; managementTask = nil }
            try await body()
        }
        managementTask = task
        do { try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() } }
        catch is CancellationError { return }
        catch let error as V2ClientGroupInvitationError {
            guard managementGeneration == generation else { return }
            if error == .authorizationDenied {
                managementBaseline = nil; baselineDeadline = nil
                links = []; requests = []; nextRequestCursor = nil; hasEarlierRequests = false
            }
            feedback = switch error { case .authorizationDenied: "没有管理该群邀请的权限。"; case .unavailable: "邀请不存在、已撤销、已过期或次数已用完。"; case .memberLimitReached: "群成员已达上限。"; case .rateLimited: "操作过于频繁，请稍后重试。"; case .conflict: "状态已变化，请刷新后重试。"; default: "邀请服务暂不可用，请检查网络后重试。" }
        } catch {
            guard managementGeneration == generation else { return }
            if (error as? V2AuthSessionError) == .unauthenticated || (error as? V2AuthSessionError) == .sessionInvalidated {
                managementBaseline = nil; baselineDeadline = nil
                links = []; requests = []; nextRequestCursor = nil; hasEarlierRequests = false
            }
            feedback = "邀请服务暂不可用，请检查网络后重试。"
        }
    }
}

/// 群邀请管理页。
///
/// 展示该房间的邀请链接、二维码与待处理入群申请，并提供创建、撤销与审批入口。
struct V2GroupInvitationManagementSheet: View {
    @Bindable var store: V2GroupInvitationStore
    let roomID: String
    @Environment(\.dismiss) private var dismiss
    @State private var profilePageID = UUID()

    var body: some View {
        NavigationStack {
            List {
                Section("邀请链接") {
                    Button("创建 7 天邀请链接", systemImage: "link.badge.plus") { Task { await store.create(roomID: roomID) } }
                        .disabled(store.isWorking || !store.canManage)
                        .accessibilityIdentifier("v2.group-invite.create")
                    ForEach(store.links) { link in
                        VStack(alignment: .leading, spacing: 10) {
                            Text("剩余 \(link.maximumApprovedUses - link.approvedUseCount) 次 · \(link.expiresAt, format: .dateTime.month().day().hour().minute()) 到期").font(.subheadline)
                            if let image = groupInviteQRCode(V2GroupInvitationStore.inviteURL(for: link.secret).absoluteString) {
                                Image(uiImage: image).interpolation(.none).resizable().scaledToFit().frame(maxWidth: 180).accessibilityLabel("群邀请二维码").accessibilityIdentifier("v2.group-invite.qr.\(link.inviteID.rawValue)")
                            }
                            HStack {
                                ShareLink(item: V2GroupInvitationStore.inviteURL(for: link.secret)) { Label("分享", systemImage: "square.and.arrow.up") }
                                    .accessibilityIdentifier("v2.group-invite.share.\(link.inviteID.rawValue)")
                                Spacer()
                                Button("撤销", role: .destructive) { Task { await store.revoke(link) } }.disabled(store.isWorking || !store.canManage).accessibilityIdentifier("v2.group-invite.revoke.\(link.inviteID.rawValue)")
                            }
                        }
                        .accessibilityIdentifier("v2.group-invite.link.\(link.inviteID.rawValue)")
                    }
                }
                Section("待审批") {
                    if store.requests.isEmpty { Text("暂无入群申请").foregroundStyle(.secondary) }
                    ForEach(store.requests) { request in
                        VStack(alignment: .leading, spacing: 8) {
                            V2AuthorizedAvatarView(key: request.presentationKey, showsName: true)
                            if let note = request.note { Text(note) }
                            HStack {
                                Button("拒绝", role: .destructive) { Task { await store.decide(request, decision: .reject) } }.accessibilityIdentifier("v2.group-join-request.reject.\(request.requestID.rawValue)")
                                Spacer()
                                Button("批准") { Task { await store.decide(request, decision: .approve) } }.buttonStyle(.borderedProminent).accessibilityIdentifier("v2.group-join-request.approve.\(request.requestID.rawValue)")
                            }.disabled(store.isWorking || !store.canManage)
                        }
                        .accessibilityIdentifier("v2.group-join-request.\(request.requestID.rawValue)")
                    }
                    if store.nextRequestCursor != nil {
                        Button("加载更多") { Task { await store.loadMoreRequests(roomID: roomID) } }
                            .disabled(store.isWorking)
                            .accessibilityIdentifier("v2.group-join-request.load-more")
                    }
                    if store.hasEarlierRequests {
                        Button("返回列表开头") { Task { await store.loadManagement(roomID: roomID) } }
                            .disabled(store.isWorking)
                    }
                }
                invitationPendingSection(store:store)
                if let feedback = store.feedback { Text(feedback).foregroundStyle(.secondary).accessibilityIdentifier("v2.group-invite.feedback") }
            }
            .navigationTitle("群邀请与审批")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.accessibilityIdentifier("v2.group-invite.done") } }
            .refreshable { await store.loadManagement(roomID: roomID) }
            .task { await store.loadManagement(roomID: roomID) }
            .task { await store.observePending(roomID:roomID) }
        }
        .authorPresentationPage(context: .list(profilePageID))
        .onDisappear { store.endManagement() }
    }
}

/// 入群申请页。
///
/// 支持粘贴链接或扫码进入预览，并在预览通过后提交带附言的入群申请。
struct V2GroupJoinSheet: View {
    @Bindable var store: V2GroupInvitationStore
    @State private var input = ""
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                if let preview = store.preview {
                    Section("群聊") { Text(preview.roomTitle).font(.headline); Text(preview.expiresAt, format: .dateTime.year().month().day().hour().minute()).foregroundStyle(.secondary) }
                    if !preview.isAlreadyMember && (preview.requestState == nil || preview.requestState == .cancelled) {
                        Section("申请说明") { TextField("可选，最多 500 字节", text: $note, axis: .vertical).accessibilityIdentifier("v2.group-join.note") }
                        Button("提交入群申请") { Task { await store.submit(note: note) } }.disabled(!store.canSubmit).accessibilityIdentifier("v2.group-join.submit")
                    } else {
                        Section("状态") {
                            Text(groupJoinStatus(preview))
                                .accessibilityIdentifier("v2.group-join.status")
                            if preview.requestState == .pending {
                                Button("取消申请", role: .destructive) { Task { await store.cancelRequest() } }
                                    .disabled(!store.canCancelRequest)
                                    .accessibilityIdentifier("v2.group-join.cancel")
                            }
                        }
                    }
                } else {
                    Section("邀请链接") {
                        TextField("粘贴链接或令牌", text: $input).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("v2.group-join.input")
                        Button("读取邀请") { Task { await store.open(input) } }.disabled(input.isEmpty).accessibilityIdentifier("v2.group-join.preview")
                        Button("扫描二维码", systemImage: "qrcode.viewfinder") { store.isPresentingScanner = true }.disabled(!DataScannerViewController.isSupported || !DataScannerViewController.isAvailable).accessibilityIdentifier("v2.group-join.scan")
                    }
                }
                invitationPendingSection(store:store)
                if store.isJoining { ProgressView() }
                if let feedback = store.joinFeedback { Text(feedback).foregroundStyle(.secondary).accessibilityIdentifier("v2.group-join.feedback") }
            }
            .task(id:store.preview?.roomID.rawValue) {if let room=store.preview?.roomID.rawValue {await store.observePending(roomID:room)}}
            .navigationTitle("加入群聊")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { store.dismissJoin() }.accessibilityIdentifier("v2.group-join.close") } }
            .sheet(isPresented: $store.isPresentingScanner) { V2GroupInviteScanner { value in store.isPresentingScanner = false; Task { await store.open(value) } } }
        }
    }
}

/// 使用 VisionKit 扫描群邀请二维码的 SwiftUI 包装。
private struct V2GroupInviteScanner: UIViewControllerRepresentable {
    let found: @MainActor (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(found: found) }
    func makeUIViewController(context: Context) -> DataScannerViewController { let controller = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], recognizesMultipleItems: false); controller.delegate = context.coordinator; try? controller.startScanning(); return controller }
    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}
    static func dismantleUIViewController(_ uiViewController: DataScannerViewController, coordinator: Coordinator) { uiViewController.stopScanning() }
    /// 把识别到的二维码文本回调给调用方。
    @MainActor final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: @MainActor (String) -> Void
        init(found: @escaping @MainActor (String) -> Void) { self.found = found }
        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) { if case .barcode(let barcode) = item, let value = barcode.payloadStringValue { found(value) } }
        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) { guard let item = addedItems.first, case .barcode(let barcode) = item, let value = barcode.payloadStringValue else { return }; found(value) }
    }
}

private func groupInviteQRCode(_ value: String) -> UIImage? {
    let filter = CIFilter.qrCodeGenerator(); filter.message = Data(value.utf8); filter.correctionLevel = "M"
    guard let output = filter.outputImage?.transformed(by: .init(scaleX: 8, y: 8)), let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
    return UIImage(cgImage: image)
}

private func groupJoinStatus(_ preview: V2GroupInvitePreview) -> String {
    if preview.isAlreadyMember { return "你已经是该群成员。" }
    return switch preview.requestState {
    case .pending, .approving: "入群申请正在等待审批。"
    case .approved: "入群申请已批准。"
    case .rejected: "入群申请已拒绝。"
    case .cancelled: "入群申请已取消。"
    case nil: "可以提交入群申请。"
    }
}

@MainActor
private func invitationPendingSection(store:V2GroupInvitationStore) -> some View {
    Section("持久邀请任务") {
        ForEach(store.pending,id:\.id) { value in
            VStack(alignment:.leading) {
                Text(invitationProposalDescription(value.intent.action))
                Text(value.work.map {$0.scheduling == .finished ? ($0.execution == .committed ? "原操作已有权威结果" : "原操作已关闭或拒绝，未确认新变更") : "原操作结果待确认"} ?? "邀请提案待确认")
                if let work=value.work,work.scheduling == .needsAttention {Button("继续核对原操作") {Task {await store.resume(value)}}}
                if value.work==nil,value.confirmationRequired {
                    Button("明确重新确认提案") {Task {await store.reconfirm(value)}}
                    Button("仅核对并关闭原操作") {Task {await store.resume(value)}}
                }
                if value.work==nil {Button("移除未提交草稿",role:.destructive) {Task {await store.discard(value)}}}
            }
        }
    }
}

private func invitationProposalDescription(_ action:V2GroupInvitationOperationAction) -> String {
    switch action {
    case .create(let seconds,let uses,_):"创建邀请：有效期\(seconds)秒，最多\(uses)次"
    case .revoke(let invite,_):"撤销邀请 \(invite.rawValue)"
    case .submit(_,_,let note):"申请加入：\(note ?? "无附言")"
    case .cancel(let request):"取消申请 \(request.rawValue)"
    case .decide(let request,let decision,_):"审批申请 \(request.rawValue)：\(decision == .approve ? "批准" : "拒绝")"
    }
}
