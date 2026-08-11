import Fluent
import Foundation
import IMV2Core
import SQLKit

/// The only server-facing input accepted for a special-account send. It is
/// intentionally absent from the public protobuf gateway: callers must first
/// authenticate as a deployment-controlled service principal.
public struct V2TrustedSpecialAccountMessage: Sendable {
    public let stableAccountKey: String
    public let servicePrincipal: String
    public let operatorID: String?
    public let operationID: ClientMessageID
    public let requestFingerprint: String
    public let customerUserID: UserID
    public let text: String
    public let media: [V2MediaReference]
    public let mentions: [V2MentionTarget]
    public let entities: [V2MessageEntity]
    public let replyTo: V2MessageReplyReference?

    public init(
        stableAccountKey: String,
        servicePrincipal: String,
        operatorID: String? = nil,
        operationID: ClientMessageID,
        requestFingerprint: String,
        customerUserID: UserID,
        text: String,
        media: [V2MediaReference] = [],
        mentions: [V2MentionTarget] = [],
        entities: [V2MessageEntity] = [],
        replyTo: V2MessageReplyReference? = nil
    ) throws {
        let key = stableAccountKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let principal = servicePrincipal.trimmingCharacters(in: .whitespacesAndNewlines)
        let fingerprint = requestFingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.range(of: "^[a-z][a-z0-9_]{2,63}$", options: .regularExpression) != nil,
              (1 ... 128).contains(principal.utf8.count),
              (16 ... 128).contains(fingerprint.utf8.count),
              operatorID.map({ (1 ... 128).contains($0.utf8.count) }) ?? true
        else { throw V2SpecialAccountMessagingError.invalidRequest }
        self.stableAccountKey = key
        self.servicePrincipal = principal
        self.operatorID = operatorID
        self.operationID = operationID
        self.requestFingerprint = fingerprint
        self.customerUserID = customerUserID
        self.text = text
        self.media = media
        self.mentions = mentions
        self.entities = entities
        self.replyTo = replyTo
    }
}

public struct V2ResolvedSpecialAccount: Equatable, Sendable {
    public let userID: UserID
    public let stableKey: String
    public let kind: V2AccountKind

    public init(userID: UserID, stableKey: String, kind: V2AccountKind) {
        self.userID = userID
        self.stableKey = stableKey
        self.kind = kind
    }
}

public protocol V2SpecialAccountMessagingStore: Sendable {
    func resolveActiveAccount(stableKey: String) async throws -> V2ResolvedSpecialAccount?
    func authorizeOutbound(account: V2ResolvedSpecialAccount, roomID: RoomID, customerUserID: UserID) async throws
    func record(
        request: V2TrustedSpecialAccountMessage,
        account: V2ResolvedSpecialAccount,
        roomID: RoomID,
        outcome: V2SendMessageOutcome,
        now: Date
    ) async throws
}

/// Coordinates the two idempotent existing write paths (direct-room open and
/// message accept) with a special-account registry/audit boundary. A retry can
/// leave an empty direct room after a transient failure, but can never create
/// a second customer-visible message: both underlying operations use the same
/// caller-provided operation ID.
public struct V2TrustedSpecialAccountMessagingService: Sendable {
    private let store: any V2SpecialAccountMessagingStore
    private let directMessaging: V2DirectMessagingService
    private let messages: V2SendMessageService
    private let now: @Sendable () -> Date

    public init(
        store: any V2SpecialAccountMessagingStore,
        directMessaging: V2DirectMessagingService,
        messages: V2SendMessageService,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.directMessaging = directMessaging
        self.messages = messages
        self.now = now
    }

    public func send(_ request: V2TrustedSpecialAccountMessage) async throws -> V2SendMessageOutcome {
        guard let account = try await store.resolveActiveAccount(stableKey: request.stableAccountKey) else {
            throw V2SpecialAccountMessagingError.accountUnavailable
        }
        let opened = try await directMessaging.open(
            actorUserID: account.userID,
            operationID: try .init(request.operationID.rawValue),
            targetUserID: request.customerUserID
        )
        let roomID: RoomID
        switch opened {
        case .opened(let room), .idempotent(let room): roomID = room.roomID
        case .idempotencyConflict: throw V2SpecialAccountMessagingError.idempotencyConflict
        case .unavailable: throw V2SpecialAccountMessagingError.unavailable
        }
        try await store.authorizeOutbound(account: account, roomID: roomID, customerUserID: request.customerUserID)
        let outcome = try await messages.send(.init(
            roomID: roomID,
            actorUserID: account.userID,
            clientMessageID: request.operationID,
            text: request.text,
            media: request.media,
            mentions: request.mentions,
            entities: request.entities,
            replyTo: request.replyTo
        ))
        switch outcome {
        case .accepted, .idempotent:
            try await store.record(request: request, account: account, roomID: roomID, outcome: outcome, now: now())
        case .idempotencyConflict: throw V2SpecialAccountMessagingError.idempotencyConflict
        case .rateLimited, .unavailable: throw V2SpecialAccountMessagingError.unavailable
        case .denied: throw V2SpecialAccountMessagingError.deliveryDenied
        }
        return outcome
    }
}

public enum V2SpecialAccountMessagingError: Error, Equatable, Sendable {
    case invalidRequest
    case accountUnavailable
    case deliveryDenied
    case idempotencyConflict
    case unavailable
    case corruptPersistenceState
}

public struct PostgresV2SpecialAccountMessagingStore: V2SpecialAccountMessagingStore {
    private let database: any Database

    public init(database: any Database) {
        self.database = database
    }

    public func resolveActiveAccount(stableKey: String) async throws -> V2ResolvedSpecialAccount? {
        guard let sql = database as? any SQLDatabase else { throw V2SpecialAccountMessagingError.corruptPersistenceState }
        guard let row = try await sql.raw("SELECT account_user_id, stable_key, account_kind FROM im_v2.special_accounts WHERE stable_key = \(bind: stableKey) AND status = 'active' AND allows_service_messages").first(decoding: SpecialAccountRow.self), let kind = V2AccountKind(rawValue: row.accountKind) else {
            return nil
        }
        return try .init(userID: .init(row.userID.uuidString), stableKey: row.stableKey, kind: kind)
    }

    public func authorizeOutbound(account: V2ResolvedSpecialAccount, roomID: RoomID, customerUserID: UserID) async throws {
        guard let sql = database as? any SQLDatabase,
              let roomUUID = UUID(uuidString: roomID.rawValue),
              let accountUUID = UUID(uuidString: account.userID.rawValue),
              let customerUUID = UUID(uuidString: customerUserID.rawValue)
        else { throw V2SpecialAccountMessagingError.corruptPersistenceState }
        if account.kind == .system { return }
        let permitted = try await sql.raw("SELECT EXISTS (SELECT 1 FROM im_v2.support_conversation_sessions WHERE room_id = \(bind: roomUUID) AND support_account_user_id = \(bind: accountUUID) AND customer_user_id = \(bind: customerUUID) AND state IN ('open', 'assigned', 'waiting_customer')) AS value").first(decoding: SpecialAccountBooleanRow.self)?.value ?? false
        guard permitted else { throw V2SpecialAccountMessagingError.deliveryDenied }
    }

    public func record(request: V2TrustedSpecialAccountMessage, account: V2ResolvedSpecialAccount, roomID: RoomID, outcome: V2SendMessageOutcome, now: Date) async throws {
        let message: V2AcceptedMessage
        switch outcome {
        case .accepted(let value), .idempotent(let value): message = value
        case .idempotencyConflict, .rateLimited, .unavailable, .denied: throw V2SpecialAccountMessagingError.corruptPersistenceState
        }
        guard let accountUUID = UUID(uuidString: account.userID.rawValue),
              let operationUUID = UUID(uuidString: request.operationID.rawValue),
              let roomUUID = UUID(uuidString: roomID.rawValue),
              let messageUUID = UUID(uuidString: message.messageID.rawValue)
        else { throw V2SpecialAccountMessagingError.corruptPersistenceState }
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2SpecialAccountMessagingError.corruptPersistenceState }
            if let existing = try await sql.raw("SELECT request_fingerprint, message_id FROM im_v2.special_account_message_operations WHERE account_user_id = \(bind: accountUUID) AND operation_id = \(bind: operationUUID) FOR UPDATE").first(decoding: SpecialAccountOperationRow.self) {
                guard existing.requestFingerprint == request.requestFingerprint, existing.messageID == messageUUID else {
                    throw V2SpecialAccountMessagingError.idempotencyConflict
                }
                return
            }
            try await sql.raw("INSERT INTO im_v2.special_account_message_operations (account_user_id, operation_id, request_fingerprint, room_id, message_id, created_at) VALUES (\(bind: accountUUID), \(bind: operationUUID), \(bind: request.requestFingerprint), \(bind: roomUUID), \(bind: messageUUID), \(bind: now))").run()
            let supportRoomID: UUID? = account.kind == .customerSupport ? roomUUID : nil
            try await sql.raw("INSERT INTO im_v2.special_account_message_audit (message_id, account_user_id, service_principal, operator_id, support_session_room_id, content_fingerprint, created_at) VALUES (\(bind: messageUUID), \(bind: accountUUID), \(bind: request.servicePrincipal), \(bind: request.operatorID), \(bind: supportRoomID), \(bind: request.requestFingerprint), \(bind: now)) ON CONFLICT (message_id) DO NOTHING").run()
        }
    }
}

private struct SpecialAccountRow: Decodable {
    let userID: UUID
    let stableKey: String
    let accountKind: String
    enum CodingKeys: String, CodingKey { case userID = "account_user_id"; case stableKey = "stable_key"; case accountKind = "account_kind" }
}
private struct SpecialAccountBooleanRow: Decodable { let value: Bool }
private struct SpecialAccountOperationRow: Decodable {
    let requestFingerprint: String
    let messageID: UUID
    enum CodingKeys: String, CodingKey { case requestFingerprint = "request_fingerprint"; case messageID = "message_id" }
}
