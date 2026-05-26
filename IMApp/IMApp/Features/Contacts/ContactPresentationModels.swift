import Foundation
import Observation
import SwiftUI
import IMClientKit

enum ContactNoticeScope: String, Equatable, Sendable {
    case contactsHome
    case requests
    case detail
    case blockedUsers
    case form
}

enum ContactNoticeTone: Equatable, Sendable {
    case success
    case info
    case warning
    case error

    var appStatusTone: AppStatusBanner.Tone {
        switch self {
        case .success:
            return .success
        case .info:
            return .info
        case .warning:
            return .warning
        case .error:
            return .error
        }
    }
}

struct ContactNotice: Identifiable, Equatable, Sendable {
    let id: UUID
    let scope: ContactNoticeScope
    let tone: ContactNoticeTone
    let message: String
    let createdAt: Date

    init(
        id: UUID = UUID(),
        scope: ContactNoticeScope,
        tone: ContactNoticeTone,
        message: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.scope = scope
        self.tone = tone
        self.message = message
        self.createdAt = createdAt
    }
}

struct ContactOperationResult: Equatable, Sendable {
    let succeeded: Bool
    let tone: ContactNoticeTone
    let message: String

    static func success(_ message: String) -> ContactOperationResult {
        ContactOperationResult(succeeded: true, tone: .success, message: message)
    }

    static func failure(_ message: String) -> ContactOperationResult {
        ContactOperationResult(succeeded: false, tone: .error, message: message)
    }

    static func warning(_ message: String) -> ContactOperationResult {
        ContactOperationResult(succeeded: false, tone: .warning, message: message)
    }
}

enum ContactOperationErrorMapper {
    private enum Messages {
        static let genericFailure = "操作失败，请稍后重试。"
        static let offline = "当前网络不可用，请稍后重试。"
        static let unauthorized = "当前登录已失效，请重新登录。"
        static let rateLimited = "操作过于频繁，请稍后重试。"
        static let serverUnavailable = "服务器暂时不可用，请稍后重试。"
        static let duplicateRelationship = "对方已经是联系人或申请已存在。"
        static let requestUnavailable = "该申请不存在或已被处理。"
        static let blockedRelationship = "当前关系状态不可操作，请刷新后重试。"
    }

    static func message(for error: Error) -> String {
        guard let apiError = error as? APIError else {
            return Messages.genericFailure
        }

        switch apiError {
        case .connectivity, .timeout:
            return Messages.offline
        case .unauthorized:
            return Messages.unauthorized
        case .rateLimited(let retryAfter, _):
            if let retryAfter {
                return "操作过于频繁，请在 \(Int(retryAfter)) 秒后重试。"
            }
            return Messages.rateLimited
        case .validationFailed(let message):
            return mappedValidationMessage(message)
        case .forbidden(let message):
            return mappedRelationshipMessage(message)
        case .server(let statusCode, let message):
            if 500..<600 ~= statusCode {
                return Messages.serverUnavailable
            }
            return mappedRelationshipMessage(message)
        case .cancelled:
            return ""
        default:
            return apiError.localizedDescription
        }
    }

    private static func mappedValidationMessage(_ message: String) -> String {
        let normalized = message.lowercased()
        if normalized.contains("contact") || message.contains("好友") || message.contains("联系人") {
            if message.contains("已") || normalized.contains("already") {
                return Messages.duplicateRelationship
            }
            if message.contains("不存在") || normalized.contains("not found") {
                return Messages.requestUnavailable
            }
        }
        return message.isEmpty ? Messages.genericFailure : message
    }

    private static func mappedRelationshipMessage(_ message: String) -> String {
        let normalized = message.lowercased()
        if message.contains("拉黑") || message.contains("黑名单") || normalized.contains("block") {
            return Messages.blockedRelationship
        }
        if message.contains("不存在") || normalized.contains("not found") {
            return Messages.requestUnavailable
        }
        return message.isEmpty ? Messages.genericFailure : message
    }
}

struct DirectRelationshipNotice: Equatable, Sendable {
    let conversationID: String
    let tone: ContactNoticeTone
    let message: String
    let createdAt: Date

    init(
        conversationID: String,
        tone: ContactNoticeTone,
        message: String,
        createdAt: Date = Date()
    ) {
        self.conversationID = conversationID
        self.tone = tone
        self.message = message
        self.createdAt = createdAt
    }
}

struct ContactRequestResendDraft: Identifiable, Equatable, Sendable {
    let sourceRequestID: UUID
    let email: String
    let message: String
    let remark: String

    var id: UUID {
        sourceRequestID
    }
}

enum ContactRequestResendRecoveryState: Equatable, Sendable {
    case idle
    case waitingForRetry(ContactRequestResendDraft)
    case retrying(ContactRequestResendDraft)
}

enum ContactViewTaskKey: Hashable, Sendable {
    case refresh(String)
    case sendRequest
    case accept(UUID)
    case decline(UUID)
    case cancel(UUID)
    case resend(UUID)
    case startConversation(UUID)
    case delete(UUID)
    case block(UUID)
    case report(UUID)
    case unblock(UUID)
}

@MainActor
@Observable
final class ContactTaskBag {
    private struct ActiveTask {
        let token: UUID
        let task: Task<Void, Never>
    }

    @ObservationIgnored
    private var activeTasks: [ContactViewTaskKey: ActiveTask] = [:]

    @discardableResult
    func run(
        _ key: ContactViewTaskKey,
        operation: @escaping @MainActor () async -> Void
    ) -> Bool {
        guard activeTasks[key] == nil else {
            return false
        }

        let token = UUID()
        let task = Task { @MainActor in
            await operation()
            guard !Task.isCancelled else {
                return
            }
            guard activeTasks[key]?.token == token else {
                return
            }
            activeTasks[key] = nil
        }
        activeTasks[key] = ActiveTask(token: token, task: task)
        return true
    }

    func isRunning(_ key: ContactViewTaskKey) -> Bool {
        activeTasks[key] != nil
    }

    func cancel(_ key: ContactViewTaskKey) {
        activeTasks[key]?.task.cancel()
        activeTasks[key] = nil
    }

    func cancelAll() {
        activeTasks.values.forEach { $0.task.cancel() }
        activeTasks.removeAll()
    }
}

@MainActor
@Observable
final class ContactRequestClock {
    static let refreshInterval: TimeInterval = 60

    var now: Date

    init(now: Date = Date()) {
        self.now = now
    }

    func update(to date: Date = Date()) {
        now = date
    }
}

struct ContactRequestFormModel: Equatable {
    static let maxMessageLength = 120
    static let maxRemarkLength = 40

    var email = ""
    var message = ""
    var remark = ""

    var normalizedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var normalizedMessage: String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedRemark: String {
        remark.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func validation(
        currentUserEmail: String?,
        currentUserID: UUID?,
        contacts: [ContactResponseBody],
        requests: [ContactRequestResponseBody],
        now: Date = Date()
    ) -> ContactRequestFormValidation {
        if normalizedEmail.isEmpty {
            return .invalid("请输入联系人邮箱。")
        }

        if !Self.isPlausibleEmail(normalizedEmail) {
            return .invalid("请输入有效的邮箱地址。")
        }

        if normalizedEmail == currentUserEmail?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            return .invalid("不能添加自己为好友。")
        }

        if contacts.contains(where: { $0.email.lowercased() == normalizedEmail }) {
            return .invalid("该用户已经在通讯录中。")
        }

        if hasActivePendingRequest(
            currentUserID: currentUserID,
            requests: requests,
            now: now
        ) {
            return .invalid("已有待处理的好友申请。")
        }

        if normalizedMessage.count > Self.maxMessageLength {
            return .invalid("验证消息不能超过 \(Self.maxMessageLength) 个字符。")
        }

        if normalizedRemark.count > Self.maxRemarkLength {
            return .invalid("备注不能超过 \(Self.maxRemarkLength) 个字符。")
        }

        return .valid
    }

    private func hasActivePendingRequest(
        currentUserID: UUID?,
        requests: [ContactRequestResponseBody],
        now: Date
    ) -> Bool {
        requests.contains { request in
            guard request.status == .pending,
                  !ContactRequestPresentationState.isExpired(request: request, now: now),
                  request.peerUser(for: currentUserID).email.lowercased() == normalizedEmail
            else {
                return false
            }
            return true
        }
    }

    private static func isPlausibleEmail(_ email: String) -> Bool {
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let local = parts.first,
              let domain = parts.last,
              !local.isEmpty,
              domain.contains("."),
              !domain.hasPrefix("."),
              !domain.hasSuffix(".")
        else {
            return false
        }

        return !email.contains(" ")
    }
}

struct ContactRequestFormValidation: Equatable {
    let message: String?

    static let valid = ContactRequestFormValidation(message: nil)

    static func invalid(_ message: String) -> ContactRequestFormValidation {
        ContactRequestFormValidation(message: message)
    }

    var isValid: Bool {
        message == nil
    }
}

struct ContactRemarkFormModel: Equatable {
    static let maxRemarkLength = 40

    var remark = ""

    var normalizedRemark: String {
        remark.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var validationMessage: String? {
        if normalizedRemark.count > Self.maxRemarkLength {
            return "备注不能超过 \(Self.maxRemarkLength) 个字符。"
        }
        return nil
    }

    var canSubmit: Bool {
        validationMessage == nil
    }
}

enum ContactRequestPresentationState: Equatable, Sendable {
    static let expirationInterval: TimeInterval = 14 * 24 * 60 * 60

    case incomingPending
    case outgoingPending
    case accepted
    case declined
    case cancelled
    case expired

    static func resolve(
        request: ContactRequestResponseBody,
        currentUserID: UUID?,
        now: Date
    ) -> ContactRequestPresentationState {
        if request.status == .pending,
           isExpired(request: request, now: now) {
            return .expired
        }

        switch request.status {
        case .pending:
            return request.addressee.id == currentUserID ? .incomingPending : .outgoingPending
        case .accepted:
            return .accepted
        case .declined:
            return .declined
        case .cancelled:
            return .cancelled
        }
    }

    static func isExpired(request: ContactRequestResponseBody, now: Date) -> Bool {
        guard let createdAt = request.createdAt else {
            return false
        }
        return now.timeIntervalSince(createdAt) >= expirationInterval
    }

    var isPendingActionable: Bool {
        switch self {
        case .incomingPending, .outgoingPending:
            return true
        case .accepted, .declined, .cancelled, .expired:
            return false
        }
    }
}

struct ContactRequestPresentation: Identifiable, Equatable {
    let request: ContactRequestResponseBody
    let currentUserID: UUID?
    let state: ContactRequestPresentationState

    var id: UUID { request.id }

    var peer: AuthUser {
        request.peerUser(for: currentUserID)
    }

    var isIncoming: Bool {
        request.addressee.id == currentUserID
    }

    var isOutgoing: Bool {
        request.requester.id == currentUserID
    }

    var title: String {
        peer.preferredDisplayName
    }

    var email: String {
        peer.email
    }

    var avatarPreset: UserAvatarPreset? {
        peer.avatarPreset
    }

    var statusTitle: String {
        switch state {
        case .incomingPending:
            return "待处理"
        case .outgoingPending:
            return "等待验证"
        case .accepted:
            return "已接受"
        case .declined:
            return "已拒绝"
        case .cancelled:
            return "已取消"
        case .expired:
            return "已过期"
        }
    }

    var statusColor: Color {
        switch state {
        case .incomingPending, .outgoingPending:
            return .orange
        case .accepted:
            return .green
        case .declined:
            return .red
        case .cancelled:
            return .secondary
        case .expired:
            return .secondary
        }
    }

    var subtitle: String {
        switch state {
        case .incomingPending:
            return request.message?.isEmpty == false ? request.message ?? "" : "请求添加你为好友"
        case .outgoingPending:
            return "等待对方验证"
        case .accepted:
            return "你与 \(title) 已成为好友。\(formattedTimestamp)"
        case .declined:
            return "好友申请已被拒绝。\(formattedTimestamp)"
        case .cancelled:
            return "好友申请已取消。\(formattedTimestamp)"
        case .expired:
            return isOutgoing ? "申请已超过 14 天，可重新发送。" : "申请已超过 14 天。"
        }
    }

    private var formattedTimestamp: String {
        guard let timestamp = request.respondedAt ?? request.updatedAt else {
            return ""
        }
        return " \(timestamp.formatted(date: .abbreviated, time: .shortened))"
    }
}

enum ContactDestructiveAction: Identifiable, Equatable {
    case delete
    case block

    var id: String {
        switch self {
        case .delete:
            return "delete"
        case .block:
            return "block"
        }
    }

    var title: String {
        switch self {
        case .delete:
            return "删除联系人"
        case .block:
            return "拉入黑名单"
        }
    }

    var message: String {
        switch self {
        case .delete:
            return "删除后不会清除历史聊天记录。"
        case .block:
            return "拉黑后，对方不能向你发起好友申请、创建私聊或发送私聊消息。"
        }
    }

    var confirmationIdentifier: String {
        switch self {
        case .delete:
            return "contacts.detail.confirmDelete"
        case .block:
            return "contacts.detail.confirmBlock"
        }
    }
}

enum ContactReportReason: String, CaseIterable, Identifiable {
    case harassment = "骚扰"
    case spam = "垃圾信息"
    case fraud = "诈骗"
    case impersonation = "冒充他人"
    case other = "其他"

    var id: String { rawValue }
}

struct ContactReportFormModel: Equatable {
    static let maxDetailLength = 200

    var reason: ContactReportReason = .harassment
    var detail = ""

    var normalizedDetail: String {
        detail.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var validationMessage: String? {
        if normalizedDetail.count > Self.maxDetailLength {
            return "补充说明不能超过 \(Self.maxDetailLength) 个字符。"
        }
        return nil
    }

    var canSubmit: Bool {
        validationMessage == nil
    }
}

struct KnownContactUserDisplay: Equatable {
    let id: UUID
    let displayName: String
    let email: String?
    let avatarPreset: UserAvatarPreset?
}

struct KnownContactUserDisplayCache: Equatable {
    private var displays: [UUID: KnownContactUserDisplay] = [:]

    mutating func cache(_ display: KnownContactUserDisplay) {
        displays[display.id] = display
    }

    func display(for userID: UUID) -> KnownContactUserDisplay? {
        displays[userID]
    }

    mutating func removeAll() {
        displays.removeAll()
    }
}
