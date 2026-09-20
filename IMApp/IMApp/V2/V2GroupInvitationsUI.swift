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
    private var operationIDs: [String: UUID] = [:]
    private(set) var links: [V2GroupInviteLink] = []
    private(set) var requests: [V2GroupJoinRequest] = []
    private(set) var nextRequestCursor: String?
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
    private struct JoinIntent: Hashable {
        let secret: String
        let note: String?
    }
    private var joinState: JoinState = .idle
    @ObservationIgnored private var joinGeneration = UUID()
    @ObservationIgnored private var previewTask: Task<V2GroupInvitePreview, any Error>?
    @ObservationIgnored private var cancellationTask: Task<V2GroupJoinRequest, any Error>?
    @ObservationIgnored private var submissionTask: Task<V2ClientGroupJoinSubmissionOutcome, any Error>?
    @ObservationIgnored private var joinOperations: [JoinIntent: UUID] = [:]
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
        guard !isInvalidated else { return false }
        switch joinState {
        case .ready(let value), .retryable(let value, _):
            return !value.preview.isAlreadyMember && (value.preview.requestState == nil || value.preview.requestState == .cancelled)
        case .completed(let value, _):
            return !value.preview.isAlreadyMember && value.preview.requestState == .cancelled
        default: return false
        }
    }
    var canCancelRequest: Bool {
        !isInvalidated && !isJoining && preview?.requestState == .pending
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

    init(client: any V2ClientGroupInvitationManaging) { self.client = client }

    /// 加载该房间的邀请列表与待处理入群申请。
    ///
    /// - Parameter roomID: 目标群组房间标识。
    func loadManagement(roomID: String) async {
        guard let room = try? RoomID(roomID) else { feedback = "群聊标识无效。"; return }
        await perform { try await refreshManagement(room: room) }
    }

    /// 创建一条群邀请。
    ///
    /// - Parameters:
    ///   - roomID: 目标群组房间标识。
    ///   - lifetimeSeconds: 邀请有效期秒数，默认 7 天。
    ///   - maximumUses: 最多可被批准使用的次数，默认 100。
    func create(roomID: String, lifetimeSeconds: Int = 7 * 86_400, maximumUses: Int = 100) async {
        guard let room = try? RoomID(roomID) else { feedback = "群聊标识无效。"; return }
        let operation = operationID(for: "create:\(roomID)")
        await perform {
            _ = try await client.create(roomID: room, operationID: .init(uuid: operation), lifetimeSeconds: lifetimeSeconds, maximumApprovedUses: maximumUses)
            operationIDs["create:\(roomID)"] = nil
            try await refreshManagement(room: room)
        }
    }

    /// 撤销一条群邀请。
    ///
    /// - Parameter link: 待撤销的邀请链接。
    func revoke(_ link: V2GroupInviteLink) async {
        let key = "revoke:\(link.inviteID.rawValue)"
        let operation = operationID(for: key)
        await perform {
            try await client.revoke(inviteID: link.inviteID, roomID: link.roomID, operationID: .init(uuid: operation))
            operationIDs[key] = nil
            try await refreshManagement(room: link.roomID)
        }
    }

    /// 批准或拒绝一条入群申请。
    ///
    /// - Parameters:
    ///   - request: 待处理的入群申请。
    ///   - decision: 批准或拒绝。
    func decide(_ request: V2GroupJoinRequest, decision: V2GroupJoinDecision) async {
        let key = "decision:\(request.requestID.rawValue):\(decision.rawValue)"
        let operation = request.resumableDecisionOperationID?.uuidValue ?? operationID(for: key)
        await perform {
            _ = try await client.decide(roomID: request.roomID, requestID: request.requestID, operationID: .init(uuid: operation), decision: decision)
            operationIDs[key] = nil
            try await refreshManagement(room: request.roomID)
        }
    }

    /// 按游标继续读取待处理入群申请。
    ///
    /// - Parameter roomID: 目标群组房间标识。
    func loadMoreRequests(roomID: String) async {
        guard let room = try? RoomID(roomID), let cursor = nextRequestCursor else { return }
        await perform {
            let page = try await client.pendingRequests(roomID: room, cursor: cursor, pageSize: 100)
            let existing = Set(requests.map(\.requestID))
            requests.append(contentsOf: page.requests.filter { !existing.contains($0.requestID) })
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
        let generation = joinGeneration
        let intent = JoinIntent(secret: invitation.secret.rawValue, note: note)
        let operation = joinOperations[intent] ?? UUID()
        joinOperations[intent] = operation
        joinState = .submitting(invitation)
        let client = client
        let task = Task {
            try await client.submit(secret: invitation.secret, operationID: .init(uuid: operation), note: note)
        }
        submissionTask = task
        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard generation == joinGeneration, !isInvalidated else { return }
            let updated: V2GroupInvitePreview
            let message: String
            switch result {
            case .submitted(let request), .alreadyPending(let request):
                updated = try Self.updatedPreview(invitation.preview, request: request)
                message = "入群申请已提交，等待管理员审批。"
            case .alreadyMember(let value):
                guard value.inviteID == invitation.preview.inviteID, value.roomID == invitation.preview.roomID else {
                    throw V2ClientGroupInvitationError.invalidResponse
                }
                updated = value
                message = "你已经是该群成员。"
            case .cancelled(let request):
                updated = try Self.updatedPreview(invitation.preview, request: request)
                message = "该申请已取消，可重新提交。"
            case .rejected(let request):
                updated = try Self.updatedPreview(invitation.preview, request: request)
                message = "该邀请的入群申请已被拒绝。"
            }
            submissionTask = nil
            joinOperations[intent] = nil
            joinState = .completed(.init(secret: invitation.secret, preview: updated), message)
        } catch {
            guard generation == joinGeneration, !isInvalidated else { return }
            submissionTask = nil
            // Cancellation cannot undo an already submitted HTTP operation.
            // Keep its immutable intent/ID for a same-input retry.
            joinState = .retryable(invitation, error is CancellationError ? "申请尚未确认，可重试查询结果。" : Self.errorMessage(error))
        }
    }

    /// 取消当前待审申请；丢失响应后仍使用原申请身份查询终态。
    func cancelRequest() async {
        guard canCancelRequest, let invitation = previewedInvitation, let requestID = invitation.preview.requestID else { return }
        let generation = joinGeneration
        joinState = .cancelling(invitation)
        let client = client
        let task = Task { try await client.cancel(roomID: invitation.preview.roomID, requestID: requestID) }
        cancellationTask = task
        do {
            let request = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard generation == joinGeneration, !isInvalidated else { return }
            guard request.requestID == requestID, [.cancelled, .approved, .rejected].contains(request.state) else {
                throw V2ClientGroupInvitationError.invalidResponse
            }
            let updated = try Self.updatedPreview(invitation.preview, request: request)
            let message = request.state == .cancelled ? "入群申请已取消。" : "申请已完成审批，无法取消。"
            cancellationTask = nil
            joinOperations = joinOperations.filter { $0.key.secret != invitation.secret.rawValue }
            joinState = .completed(.init(secret: invitation.secret, preview: updated), message)
        } catch {
            guard generation == joinGeneration, !isInvalidated else { return }
            cancellationTask = nil
            joinState = .retryable(invitation, error is CancellationError ? "取消结果尚未确认，可重试查询。" : Self.errorMessage(error))
        }
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
        dismissJoin()
        joinOperations.removeAll()
        operationIDs.removeAll()
    }

    private func cancelJoinWork() {
        joinGeneration = UUID()
        previewTask?.cancel()
        previewTask = nil
        cancellationTask?.cancel()
        cancellationTask = nil
        submissionTask?.cancel()
        submissionTask = nil
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

    private func operationID(for key: String) -> UUID { if let value = operationIDs[key] { return value }; let value = UUID(); operationIDs[key] = value; return value }
    private static func updatedPreview(_ current: V2GroupInvitePreview, request: V2GroupJoinRequest) throws -> V2GroupInvitePreview {
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
        async let refreshedLinks = client.activeInvites(roomID: room)
        async let refreshedRequests = client.pendingRequests(roomID: room, cursor: nil, pageSize: 100)
        links = try await refreshedLinks
        let requestPage = try await refreshedRequests
        requests = requestPage.requests
        nextRequestCursor = requestPage.nextCursor
        feedback = nil
    }
    private func perform(_ body: () async throws -> Void) async {
        guard !isWorking, !isInvalidated else { return }
        isWorking = true
        defer { isWorking = false }
        do { try await body() }
        catch is CancellationError { return }
        catch let error as V2ClientGroupInvitationError {
            feedback = switch error { case .authorizationDenied: "没有管理该群邀请的权限。"; case .unavailable: "邀请不存在、已撤销、已过期或次数已用完。"; case .memberLimitReached: "群成员已达上限。"; case .rateLimited: "操作过于频繁，请稍后重试。"; case .conflict: "状态已变化，请刷新后重试。"; default: "邀请服务暂不可用，请检查网络后重试。" }
        } catch { feedback = "邀请服务暂不可用，请检查网络后重试。" }
    }
}

/// 群邀请管理页。
///
/// 展示该房间的邀请链接、二维码与待处理入群申请，并提供创建、撤销与审批入口。
struct V2GroupInvitationManagementSheet: View {
    @Bindable var store: V2GroupInvitationStore
    let roomID: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("邀请链接") {
                    Button("创建 7 天邀请链接", systemImage: "link.badge.plus") { Task { await store.create(roomID: roomID) } }
                        .disabled(store.isWorking)
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
                                Button("撤销", role: .destructive) { Task { await store.revoke(link) } }.disabled(store.isWorking).accessibilityIdentifier("v2.group-invite.revoke.\(link.inviteID.rawValue)")
                            }
                        }
                        .accessibilityIdentifier("v2.group-invite.link.\(link.inviteID.rawValue)")
                    }
                }
                Section("待审批") {
                    if store.requests.isEmpty { Text("暂无入群申请").foregroundStyle(.secondary) }
                    ForEach(store.requests) { request in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(request.applicant.displayName).font(.headline)
                            Text("@\(request.applicant.handle.rawValue)").font(.subheadline).foregroundStyle(.secondary)
                            if let note = request.note { Text(note) }
                            HStack {
                                Button("拒绝", role: .destructive) { Task { await store.decide(request, decision: .reject) } }.accessibilityIdentifier("v2.group-join-request.reject.\(request.requestID.rawValue)")
                                Spacer()
                                Button("批准") { Task { await store.decide(request, decision: .approve) } }.buttonStyle(.borderedProminent).accessibilityIdentifier("v2.group-join-request.approve.\(request.requestID.rawValue)")
                            }.disabled(store.isWorking)
                        }
                        .accessibilityIdentifier("v2.group-join-request.\(request.requestID.rawValue)")
                    }
                    if store.nextRequestCursor != nil {
                        Button("加载更多") { Task { await store.loadMoreRequests(roomID: roomID) } }
                            .disabled(store.isWorking)
                            .accessibilityIdentifier("v2.group-join-request.load-more")
                    }
                }
                if let feedback = store.feedback { Text(feedback).foregroundStyle(.secondary).accessibilityIdentifier("v2.group-invite.feedback") }
            }
            .navigationTitle("群邀请与审批")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() }.accessibilityIdentifier("v2.group-invite.done") } }
            .refreshable { await store.loadManagement(roomID: roomID) }
            .task { await store.loadManagement(roomID: roomID) }
        }
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
                if store.isJoining { ProgressView() }
                if let feedback = store.joinFeedback { Text(feedback).foregroundStyle(.secondary).accessibilityIdentifier("v2.group-join.feedback") }
            }
            .navigationTitle("加入群聊")
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
