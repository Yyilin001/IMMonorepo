import Fluent
import Foundation
import IMV2Core
import SQLKit

/// 特殊账号发送唯一接受的服务端输入。
///
/// 该结构刻意不出现在公开 protobuf 网关中：调用方必须先以部署方控制的服务主体完成认证。
public struct V2TrustedSpecialAccountMessage: Sendable {
    /// 稳定账号键。
    public let stableAccountKey: String
    /// 已认证的服务主体标识。
    public let servicePrincipal: String
    /// 运维人员标识；由服务主体自行决定是否提供。
    public let operatorID: String?
    /// 本次发送的幂等操作标识。
    public let operationID: ClientMessageID
    /// 请求指纹，用于区分同标识下的不同载荷。
    public let requestFingerprint: String
    /// 接收消息的客户用户。
    public let customerUserID: UserID
    /// 消息正文。
    public let text: String
    /// 引用的媒体。
    public let media: [V2MediaReference]
    /// 提及目标。
    public let mentions: [V2MentionTarget]
    /// 富文本实体。
    public let entities: [V2MessageEntity]
    /// 引用回复目标。
    public let replyTo: V2MessageReplyReference?

    /// 校验并保存特殊账号消息请求。
    ///
    /// 账号键需匹配 `^[a-z][a-z0-9_]{2,63}$`；服务主体长度需在 1 至 128 字节之间；
    /// 请求指纹长度需在 16 至 128 字节之间；运维标识若提供则不超过 128 字节。
    ///
    /// - Parameters:
    ///   - stableAccountKey: 稳定账号键。
    ///   - servicePrincipal: 已认证服务主体标识。
    ///   - operatorID: 运维人员标识。
    ///   - operationID: 幂等操作标识。
    ///   - requestFingerprint: 请求指纹。
    ///   - customerUserID: 接收消息的客户用户。
    ///   - text: 消息正文。
    ///   - media: 引用的媒体，默认空。
    ///   - mentions: 提及目标，默认空。
    ///   - entities: 富文本实体，默认空。
    ///   - replyTo: 引用回复目标，默认无。
    /// - Throws: 任一字段不满足上述约束时抛出
    ///   ``V2SpecialAccountMessagingError/invalidRequest``。
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

/// 已解析的特殊账号。
public struct V2ResolvedSpecialAccount: Equatable, Sendable {
    /// 账号对应的用户。
    public let userID: UserID
    /// 稳定账号键。
    public let stableKey: String
    /// 账号类型。
    public let kind: V2AccountKind

    /// 保存已解析账号。
    ///
    /// - Parameters:
    ///   - userID: 账号对应的用户。
    ///   - stableKey: 稳定账号键。
    ///   - kind: 账号类型。
    public init(userID: UserID, stableKey: String, kind: V2AccountKind) {
        self.userID = userID
        self.stableKey = stableKey
        self.kind = kind
    }
}

/// 特殊账号消息的注册与审计边界。
public protocol V2SpecialAccountMessagingStore: Sendable {
    /// 按稳定键解析处于可用状态的账号。
    ///
    /// - Parameter stableKey: 稳定账号键。
    /// - Returns: 已解析账号；账号不存在、未启用或不允许服务消息时返回 `nil`。
    /// - Throws: 持久化失败时抛出。
    func resolveActiveAccount(stableKey: String) async throws -> V2ResolvedSpecialAccount?

    /// 校验该账号是否可以向该客户房间发送消息。
    ///
    /// - Parameters:
    ///   - account: 已解析账号。
    ///   - roomID: 目标房间。
    ///   - customerUserID: 客户用户。
    /// - Throws: 不具备会话资格或持久化失败时抛出。
    func authorizeOutbound(account: V2ResolvedSpecialAccount, roomID: RoomID, customerUserID: UserID) async throws

    /// 记录一次已接受的特殊账号发送。
    ///
    /// - Parameters:
    ///   - request: 原始请求。
    ///   - account: 已解析账号。
    ///   - roomID: 目标房间。
    ///   - outcome: 消息发送结果。
    ///   - now: 服务端统一授时时刻。
    /// - Throws: 结果缺少接受回执、幂等载荷不一致或持久化失败时抛出。
    func record(
        request: V2TrustedSpecialAccountMessage,
        account: V2ResolvedSpecialAccount,
        roomID: RoomID,
        outcome: V2SendMessageOutcome,
        now: Date
    ) async throws
}

/// 把两条既有的幂等写入路径（打开私聊房间与接受消息）与特殊账号注册表和审计边界协调起来。
///
/// 瞬时失败后的重试可能留下一个空的私聊房间，但绝不会创建第二条客户可见消息：
/// 两条底层操作使用同一个由调用方提供的操作标识。
public struct V2TrustedSpecialAccountMessagingService: Sendable {
    private let store: any V2SpecialAccountMessagingStore
    private let directMessaging: V2DirectMessagingService
    private let messages: V2SendMessageService
    private let now: @Sendable () -> Date

    /// 组合注册表存储、私聊服务与消息发送服务。
    ///
    /// - Parameters:
    ///   - store: 特殊账号注册表与审计存储。
    ///   - directMessaging: 负责打开私聊房间的服务。
    ///   - messages: 负责接受消息的服务。
    ///   - now: 可注入的当前时刻读取函数。
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

    /// 发送一条特殊账号消息。
    ///
    /// 流程为：解析可用账号、以同一操作标识打开或复用私聊房间、校验会话资格、
    /// 接受消息，最后在成功或幂等时记录审计。底层返回的限流、不可用与拒绝结果
    /// 会映射为对应的领域错误，不会留下未审计的成功发送。
    ///
    /// - Parameter request: 已校验的特殊账号消息请求。
    /// - Returns: 底层消息发送结果。
    /// - Throws: 账号不可用时抛出 ``V2SpecialAccountMessagingError/accountUnavailable``；
    ///   操作标识冲突时抛出 ``V2SpecialAccountMessagingError/idempotencyConflict``；
    ///   准入或存储不可用时抛出 ``V2SpecialAccountMessagingError/unavailable``；
    ///   会话资格不通过时抛出 ``V2SpecialAccountMessagingError/deliveryDenied``。
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

/// 特殊账号消息错误。
public enum V2SpecialAccountMessagingError: Error, Equatable, Sendable {
    /// 请求参数不满足约束。
    case invalidRequest
    /// 账号不存在、未启用或不接受服务消息。
    case accountUnavailable
    /// 当前不具备向该客户发送消息的会话资格。
    case deliveryDenied
    /// 同一操作标识已被不同载荷占用。
    case idempotencyConflict
    /// 准入或存储当前不可用。
    case unavailable
    /// 持久化记录缺失或字段无法解码。
    case corruptPersistenceState
}

/// 基于 PostgreSQL 的特殊账号注册与审计实现。
public struct PostgresV2SpecialAccountMessagingStore: V2SpecialAccountMessagingStore {
    private let database: any Database

    /// 组合数据库。
    ///
    /// - Parameter database: 存放特殊账号、会话与审计记录的数据库。
    public init(database: any Database) {
        self.database = database
    }

    /// 解析处于可用状态且允许服务消息的账号。
    ///
    /// - Parameter stableKey: 稳定账号键。
    /// - Returns: 已解析账号；不满足条件或账号类型无法解码时返回 `nil`。
    /// - Throws: 连接不支持 SQL 时抛出
    ///   ``V2SpecialAccountMessagingError/corruptPersistenceState``。
    public func resolveActiveAccount(stableKey: String) async throws -> V2ResolvedSpecialAccount? {
        guard let sql = database as? any SQLDatabase else { throw V2SpecialAccountMessagingError.corruptPersistenceState }
        guard let row = try await sql.raw("SELECT account_user_id, stable_key, account_kind FROM im_v2.special_accounts WHERE stable_key = \(bind: stableKey) AND status = 'active' AND allows_service_messages").first(decoding: SpecialAccountRow.self), let kind = V2AccountKind(rawValue: row.accountKind) else {
            return nil
        }
        return try .init(userID: .init(row.userID.uuidString), stableKey: row.stableKey, kind: kind)
    }

    /// 校验账号是否具备该客户房间的会话资格。
    ///
    /// 系统类账号无需会话记录即可发送；客服类账号必须存在处于开启、已分配或等待客户状态的会话。
    ///
    /// - Parameters:
    ///   - account: 已解析账号。
    ///   - roomID: 目标房间。
    ///   - customerUserID: 客户用户。
    /// - Throws: 标识非法或连接不支持 SQL 时抛出
    ///   ``V2SpecialAccountMessagingError/corruptPersistenceState``；
    ///   会话资格不通过时抛出 ``V2SpecialAccountMessagingError/deliveryDenied``。
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

    /// 在单个事务内写入操作记录与审计。
    ///
    /// 事务先按账号与操作标识加咨询锁，即使操作记录尚不存在也能串行化重试；
    /// 已存在记录时必须与本次的请求指纹和消息标识完全一致，否则判定幂等冲突。
    /// 审计记录以消息标识为唯一键，重复写入会被忽略。
    ///
    /// - Parameters:
    ///   - request: 原始请求。
    ///   - account: 已解析账号。
    ///   - roomID: 目标房间。
    ///   - outcome: 消息发送结果，需携带接受回执。
    ///   - now: 服务端统一授时时刻。
    /// - Throws: 结果缺少接受回执、标识非法、时刻不可编码、幂等载荷不一致或持久化失败时抛出
    ///   ``V2SpecialAccountMessagingError/corruptPersistenceState`` 或
    ///   ``V2SpecialAccountMessagingError/idempotencyConflict``。
    public func record(request: V2TrustedSpecialAccountMessage, account: V2ResolvedSpecialAccount, roomID: RoomID, outcome: V2SendMessageOutcome, now: Date) async throws {
        guard let message = outcome.acceptanceReceipt else {
            throw V2SpecialAccountMessagingError.corruptPersistenceState
        }
        guard let accountUUID = UUID(uuidString: account.userID.rawValue),
              let operationUUID = UUID(uuidString: request.operationID.rawValue),
              let roomUUID = UUID(uuidString: roomID.rawValue),
              let messageUUID = UUID(uuidString: message.messageID.rawValue),
              message.roomID.uuidValue == roomUUID,
              message.senderUserID.uuidValue == accountUUID,
              message.clientMessageID.uuidValue == operationUUID
        else { throw V2SpecialAccountMessagingError.corruptPersistenceState }
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2SpecialAccountMessagingError.corruptPersistenceState }
            // Serialize retries even when the operation row does not exist yet.
            let lockKey = "special-account-message:\(accountUUID):\(operationUUID)"
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: lockKey), 0))").run()
            if let existing = try await sql.raw("SELECT request_fingerprint, message_id, room_id FROM im_v2.special_account_message_operations WHERE account_user_id = \(bind: accountUUID) AND operation_id = \(bind: operationUUID) FOR UPDATE").first(decoding: SpecialAccountOperationRow.self) {
                guard existing.requestFingerprint == request.requestFingerprint, existing.messageID == messageUUID, existing.roomID == roomUUID else {
                    throw V2SpecialAccountMessagingError.idempotencyConflict
                }
                return
            }
            guard let room = try await sql.raw("""
                SELECT migration_fence_id FROM im_v2.rooms
                WHERE room_id = \(bind: roomUUID) FOR SHARE
                """).first(decoding: SpecialAccountRoomFenceRow.self),
                room.migrationFenceID == nil else { throw V2RoomOwnerFenceError.ownerChanged }
            guard v2PostgresTimestampCanEncode(now) else { throw V2SpecialAccountMessagingError.corruptPersistenceState }
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
    let roomID: UUID
    enum CodingKeys: String, CodingKey { case requestFingerprint = "request_fingerprint"; case messageID = "message_id"; case roomID = "room_id" }
}

private struct SpecialAccountRoomFenceRow: Decodable {
    let migrationFenceID: UUID?
    enum CodingKeys: String, CodingKey { case migrationFenceID = "migration_fence_id" }
}
