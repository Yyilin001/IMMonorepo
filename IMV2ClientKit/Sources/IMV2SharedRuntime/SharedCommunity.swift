import Foundation
import IMV2Core
import IMV2ClientRuntime

/// Per-installation/account/ref encrypted items; bearers never enter SQLite.
private struct SharedInvitationSecrets: V2InvitationSecretStoring {
    let installation: String
    let persistence: @Sendable (String) -> any SharedSecurePersistence
    private func item(_ reference: UUID, _ account: UserID) throws -> any SharedSecurePersistence {
        guard account.uuidValue != nil else { throw V2InvitationSecretStoreError.invalidReference }
        return persistence("invite-" + installation + "-" + account.rawValue + "-" + reference.uuidString)
    }
    func save(_ authorization: V2GroupInvitationSecretAuthorization, reference: UUID, accountID: UserID) throws {
        let item = try item(reference, accountID), bytes = Data(authorization.rawValue.utf8)
        if let existing = try item.load() { guard existing == bytes else { throw V2InvitationSecretStoreError.invalidSecret }; return }
        try item.save(bytes)
    }
    func load(reference: UUID, accountID: UserID) throws -> V2GroupInvitationSecretAuthorization {
        guard let data = try item(reference, accountID).load(), let value = String(data: data, encoding: .utf8) else { throw V2InvitationSecretStoreError.missing }
        return try .init(secret: .init(value))
    }
    func remove(reference: UUID, accountID: UserID) throws { try item(reference, accountID).delete() }
}
struct SharedInvite: Encodable, Sendable { let id: String; let url: String; let expires: Int64; let used: Int; let maximum: Int }
struct SharedJoinRequest: Encodable, Sendable { let id: String; let userID: String; let note: String; let state: String }
struct SharedInvitePreview: Encodable, Sendable { let roomID: String; let title: String; let requestID: String?; let state: String?; let member: Bool; let canSubmit: Bool; let canCancel: Bool }
struct SharedCommunitySnapshot: Encodable, Sendable {
    let roomID: String?; let invites: [SharedInvite]; let requests: [SharedJoinRequest]; let hasMore: Bool
    let preview: SharedInvitePreview?; let works: [SharedWork]; let failure: String?
}
actor SharedCommunity {
    private let invites: V2InvitationOperationService
    private let reader: V2HTTPGroupInvitationClient
    private let moderation: V2MemberAdministrationOperationService
    private let store: GRDBV2LocalSyncStore
    private var tasks: [Task<Void, Never>] = []
    private var observers: [Task<Void, Never>] = []
    private var room: RoomID?
    private var links: [V2GroupInviteLink] = []
    private var requests: V2ClientGroupJoinRequestPage?
    private var preview: (V2GroupInviteSecret, V2GroupInvitePreview)?
    private var invitationRows: [SharedWork] = [], muteRows: [SharedWork] = []
    private var failure: SharedFailure?
    init(account: UserID, store: GRDBV2LocalSyncStore, base: URL, http: V2SessionHTTPAuthorization, installation: String, persistence: @escaping @Sendable (String) -> any SharedSecurePersistence) throws {
        self.store = store
        let activation = UUID()
        invites = .init(accountID: account, activationID: activation, store: store,
            client: try V2HTTPInvitationOperationClient(baseURL: base, credentials: http, transport: http), secrets: SharedInvitationSecrets(installation: installation, persistence: persistence))
        reader = try .init(baseURL: base, credentials: http, transport: http)
        moderation = .init(accountID: account, activationID: activation, store: store,
            client: try V2HTTPMemberAdministrationClient(baseURL: base, credentials: http, transport: http))
    }
    func handlers() -> [V2OperationWorkDispatcher.Handler] {
        [V2OperationKind.groupInvite, .groupJoinRequest, .groupJoinDecision].map { kind in .init(kind: kind) { [invites] in try await invites.execute($0) } }
        + [.init(kind: .memberMute) { [moderation] in try await moderation.execute($0) }]
    }
    func start() {
        tasks = [Task { do { try await invites.runPreparation() } catch is CancellationError {} catch { failure = sharedFailure(error) } },
            Task { do { try await moderation.runPreparation() } catch is CancellationError {} catch { failure = sharedFailure(error) } }]
    }
    func clear() async {
        observers.forEach { $0.cancel() }; for task in observers { await task.value }
        observers = []; room = nil; links = []; requests = nil; preview = nil; invitationRows = []; muteRows = []
    }
    func close() async { tasks.forEach { $0.cancel() }; await clear(); for task in tasks { await task.value }; tasks = [] }
    private func observe(_ room: RoomID) async {
        guard self.room != room else { return }
        await clear(); self.room = room
        observers = [Task {
            do { for try await values in await invites.updates(roomID: room) {
                invitationRows = values.prefix(50).map { row in Self.work(row.work, id: row.id, kind: row.intent.action.kind.rawValue, target: room.rawValue, fallback: row.preparationState.rawValue) }
            } } catch is CancellationError {} catch { failure = sharedFailure(error) }
        }, Task {
            do { for try await values in await moderation.updates(roomID: room) {
                muteRows = values.prefix(50).map { row in Self.work(row.work, id: row.id, kind: row.intent.kind.rawValue, target: row.intent.targetUserID.rawValue, fallback: row.preparationState.rawValue) }
            } } catch is CancellationError {} catch { failure = sharedFailure(error) }
        }]
    }
    private static func work(_ work: V2OperationWork?, id: UUID, kind: String, target: String, fallback: String) -> SharedWork {
        .init(id: id.uuidString, kind: kind, target: target, status: work.map { $0.execution.isTerminal ? $0.execution.rawValue : $0.scheduling.rawValue } ?? fallback,
              retryable: work.map { !$0.execution.isTerminal && $0.scheduling == .needsAttention } ?? false, roomID: nil)
    }
    func execute(_ request: SharedRequest) async throws {
        if request.operation == .refreshInvite {
            guard let previous = preview else { throw SharedFailure.invalidInput }
            preview = nil
            let current = try await reader.preview(secret: previous.0)
            preview = (previous.0, current); return
        }
        if request.operation == .previewInvite {
            preview = nil
            let text = (request.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let raw: String
            if let url = URLComponents(string: text), url.scheme == "iim", url.host == "group-invite", url.user == nil, url.password == nil, url.fragment == nil,
               let items = url.queryItems, items.count == 1, items[0].name == "token", let token = items[0].value { raw = token }
            else { raw = text }
            let secret = try V2GroupInviteSecret(raw), value = try await reader.preview(secret: secret)
            await observe(value.roomID); preview = (secret, value); return
        }
        if request.operation == .inviteAction, request.action == "submit" {
            guard let preview, preview.1.expiresAt > Date() else { throw SharedFailure.invalidInput }
            let auth = V2GroupInvitationSecretAuthorization(secret: preview.0)
            _ = try await invites.enqueue(invites.confirmation(roomID: preview.1.roomID, action: .submit(inviteID: preview.1.inviteID, tokenDigest: auth.tokenDigest, note: request.text)), authorization: auth)
            return
        }
        guard let raw = request.roomID else { throw SharedFailure.invalidInput }
        let room = try RoomID(raw)
        if request.operation == .inviteAction, request.action == "cancel" {
            guard preview?.1.roomID == room, let id = preview?.1.requestID else { throw SharedFailure.invalidInput }
            _ = try await invites.enqueue(invites.confirmation(roomID: room, action: .cancel(requestID: id))); return
        }
        guard try await store.roomAllowsLocalRead(roomID: room) else { throw SharedFailure.invalidInput }
        await observe(room)
        switch request.operation {
        case .invitations:
            links = []; requests = nil
            links = try await reader.activeInvites(roomID: room)
            requests = try await reader.pendingRequests(roomID: room, cursor: nil, pageSize: 50)
        case .invitationsNext:
            if let cursor = requests?.nextCursor { requests = try await reader.pendingRequests(roomID: room, cursor: cursor, pageSize: 50) }
        case .inviteAction:
            guard let revision = request.revision else { throw SharedFailure.invalidInput }
            let action: V2GroupInvitationOperationAction
            switch request.action {
            case "create": action = .create(lifetimeSeconds: 3600, maximumApprovedUses: 10, expectedMembershipRevision: revision)
            case "revoke": action = .revoke(inviteID: try .init(request.intentID ?? ""), expectedMembershipRevision: revision)
            case "approve", "reject": action = .decide(requestID: try .init(request.intentID ?? ""), decision: request.action == "approve" ? .approve : .reject, expectedMembershipRevision: revision)
            default: throw SharedFailure.invalidInput
            }
            _ = try await invites.enqueue(invites.confirmation(roomID: room, action: action))
        case .muteMember:
            guard let revision = request.revision, let target = request.targetUserID else { throw SharedFailure.invalidInput }
            _ = try await moderation.enqueue(roomID: room, targetUserID: UserID(target), action: .mute(untilMilliseconds: UInt64(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000)), reasonCode: .init("group_rules"), expectedMembershipRevision: revision)
        default: throw SharedFailure.invalidInput
        }
    }
    func retry(_ id: UUID, kind: V2OperationKind) async throws {
        if kind == .memberMute { try await moderation.resumeConfirmation(id: id) } else { try await invites.resume(id: id) }
    }
    func discard(_ id: UUID) async throws -> Bool {
        if invitationRows.contains(where: { $0.id == id.uuidString && $0.status == "paused" }) { try await invites.discard(id: id); return true }
        if muteRows.contains(where: { $0.id == id.uuidString && $0.status == "paused" }) { try await moderation.discardDraft(id: id); return true }
        return false
    }
    func snapshot() async throws -> SharedCommunitySnapshot {
        let authorized = if let room { try await store.roomAllowsLocalRead(roomID: room) } else { false }
        if !authorized { links = []; requests = nil }
        if let preview, preview.1.expiresAt <= Date() { self.preview = nil }
        return .init(roomID: room?.rawValue, invites: links.filter { $0.expiresAt > Date() }.prefix(50).map {
            .init(id: $0.inviteID.rawValue, url: "iim://group-invite?token=" + $0.secret.rawValue, expires: Int64($0.expiresAt.timeIntervalSince1970 * 1000), used: $0.approvedUseCount, maximum: $0.maximumApprovedUses)
        }, requests: requests?.requests.map { .init(id: $0.requestID.rawValue, userID: $0.applicantUserID.rawValue, note: $0.note ?? "", state: $0.state.rawValue) } ?? [], hasMore: requests?.nextCursor != nil,
            preview: preview.map { .init(roomID: $0.1.roomID.rawValue, title: $0.1.roomTitle, requestID: $0.1.requestID?.rawValue, state: $0.1.requestState?.rawValue, member: $0.1.isAlreadyMember, canSubmit: !$0.1.isAlreadyMember && $0.1.requestState == nil, canCancel: $0.1.requestState == .pending) }, works: invitationRows + muteRows, failure: failure?.rawValue)
    }
}
