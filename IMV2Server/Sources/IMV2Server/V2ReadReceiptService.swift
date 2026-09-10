import Foundation
import IMV2Core

/// 通过认证的已读回执请求。
public struct V2AuthenticatedReadReceipt: Sendable {
    /// 目标房间。
    public let roomID: RoomID
    /// 发起回执的用户。
    public let actorUserID: UserID
    /// 本次回执的幂等操作标识。
    public let operationID: ReadReceiptOperationID
    /// 已读到的房间序号。
    public let readThroughRoomSequence: UInt64
    /// 保存已认证的已读回执请求。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - actorUserID: 发起回执的用户。
    ///   - operationID: 幂等操作标识。
    ///   - readThroughRoomSequence: 已读到的房间序号。
    public init(roomID: RoomID, actorUserID: UserID, operationID: ReadReceiptOperationID, readThroughRoomSequence: UInt64) { self.roomID = roomID; self.actorUserID = actorUserID; self.operationID = operationID; self.readThroughRoomSequence = readThroughRoomSequence }
}

/// 已读回执记录结果。
public enum V2ReadReceiptOutcome: Equatable, Sendable {
    /// 本次调用实际记录了回执。
    case recorded(V2ReadReceipt)
    /// 同一操作已记录过，返回其原有回执。
    case idempotent(V2ReadReceipt)
    /// 同一操作标识已被不同载荷占用。
    case idempotencyConflict
}

/// 已读回执偏好变更结果。
public enum V2SetReadReceiptPreferencesOutcome: Equatable, Sendable {
    /// 本次调用实际更新了偏好。
    case updated(V2ReadReceiptPreferences)
    /// 同一操作已提交过，返回其原有偏好。
    case idempotent(V2ReadReceiptPreferences)
    /// 同一操作标识已被不同载荷占用。
    case idempotencyConflict
}

/// 已读回执的持久化能力。
public protocol V2ReadReceiptStore: Sendable {
    /// 记录一条已读回执。
    ///
    /// - Parameters:
    ///   - command: 已读回执命令。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 记录结果。
    /// - Throws: 房间或消息不存在、非成员或持久化失败时抛出。
    func record(command: V2RecordReadReceiptCommand, now: Date) async throws -> V2ReadReceiptOutcome

    /// 设置已读回执偏好。
    ///
    /// - Parameters:
    ///   - command: 偏好变更命令。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 变更结果。
    /// - Throws: 持久化失败时抛出。
    func setPreferences(command: V2SetReadReceiptPreferencesCommand, now: Date) async throws -> V2SetReadReceiptPreferencesOutcome

    /// 分页读取读者列表。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - messageID: 目标消息。
    ///   - actorUserID: 发起查询的用户。
    ///   - cursor: 上一页游标。
    ///   - pageSize: 本页条数。
    /// - Returns: 读者分页。
    /// - Throws: 无资格、游标非法或持久化失败时抛出。
    func readers(roomID: RoomID, messageID: MessageID, actorUserID: UserID, cursor: String?, pageSize: Int) async throws -> V2ReadReceiptReadersPage
}

/// 进程内回执微批处理器保留的不可变输入。
///
/// 时间戳在命令穿过领域边界时捕获，而不是在某次延迟批量恰好到达 PostgreSQL 时才取值，
/// 这样批量延迟不会改变回执的生效时刻。
public struct V2ReadReceiptRecordRequest: Sendable {
    /// 已读回执命令。
    public let command: V2RecordReadReceiptCommand
    /// 命令穿过领域边界时的时刻。
    public let now: Date

    /// 保存待批处理请求。
    ///
    /// - Parameters:
    ///   - command: 已读回执命令。
    ///   - now: 命令进入领域边界时的时刻。
    public init(command: V2RecordReadReceiptCommand, now: Date) {
        self.command = command
        self.now = now
    }
}

/// 单条批量回执的结果。
///
/// 领域拒绝只属于对应命令，不应回滚同一物理事务中的其他回执；
/// 基础设施失败仍从批量调用抛出，并使该批全部等待者失败。
public enum V2ReadReceiptRecordResult: Equatable, Sendable {
    /// 该条回执已处理。
    case success(V2ReadReceiptOutcome)
    /// 该条回执被领域规则拒绝。
    case failure(V2ReadReceiptStoreError)
}

/// 支持批量记录的已读回执存储。
public protocol V2ReadReceiptBatchStore: V2ReadReceiptStore {
    /// 批量记录已读回执。
    ///
    /// - Parameter requests: 待记录请求列表。
    /// - Returns: 与输入顺序对应的结果。
    /// - Throws: 基础设施失败时抛出，领域拒绝以失败结果返回。
    func recordBatch(
        _ requests: [V2ReadReceiptRecordRequest]
    ) async throws -> [V2ReadReceiptRecordResult]
}

/// 已读回执持久化中属于房间归属的子集。
///
/// 群已读游标应与其校验的房间序号、成员历史放在一起；把该能力单独声明，
/// 可避免路由存储误把属于用户维度的偏好写入房间数据库。
public protocol V2GroupReadReceiptRecordingStore: Sendable {
    /// 记录一条群已读回执。
    ///
    /// - Parameters:
    ///   - command: 已读回执命令。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 记录尝试结果。
    /// - Throws: 持久化失败时抛出。
    func recordGroup(
        command: V2RecordReadReceiptCommand,
        now: Date
    ) async throws -> V2GroupReadReceiptRecordingAttempt
}

/// 群已读回执批量记录的单条结果。
public enum V2GroupReadReceiptBatchResult: Equatable, Sendable {
    /// 归属侧已处理该条回执。
    case success(V2GroupReadReceiptRecordingAttempt)
    /// 该条回执被领域规则拒绝。
    case failure(V2ReadReceiptStoreError)
}

/// 支持批量记录的群已读回执存储。
public protocol V2GroupReadReceiptBatchRecordingStore:
    V2GroupReadReceiptRecordingStore
{
    /// 批量记录群已读回执。
    ///
    /// - Parameter requests: 待记录请求列表。
    /// - Returns: 与输入顺序对应的结果。
    /// - Throws: 基础设施失败时抛出。
    func recordGroups(
        _ requests: [V2ReadReceiptRecordRequest]
    ) async throws -> [V2GroupReadReceiptBatchResult]
}

public extension V2GroupReadReceiptBatchRecordingStore {
    /// 逐条记录群已读回执的兼容实现。
    ///
    /// 领域拒绝会被捕获为该条的失败结果，不影响同批其他条目；
    /// 非领域错误仍向上抛出，使调用方能够区分拒绝与故障。
    ///
    /// - Parameter requests: 待记录请求列表。
    /// - Returns: 与输入顺序对应的结果。
    /// - Throws: 非领域错误时抛出。
    func recordGroups(
        _ requests: [V2ReadReceiptRecordRequest]
    ) async throws -> [V2GroupReadReceiptBatchResult] {
        var results: [V2GroupReadReceiptBatchResult] = []
        results.reserveCapacity(requests.count)
        for request in requests {
            do {
                results.append(.success(try await recordGroup(
                    command: request.command,
                    now: request.now
                )))
            } catch let error as V2ReadReceiptStoreError {
                results.append(.failure(error))
            }
        }
        return results
    }
}

/// 归属侧对一条群已读回执的处理结果。
public enum V2GroupReadReceiptRecordingAttempt: Equatable, Sendable {
    /// 归属侧已完成处理。
    case handled(V2ReadReceiptOutcome)
    /// 选中的物理归属中存放的是私聊房间。
    ///
    /// 调用方必须改走既有的私聊回执路径，使互见投影与双方隐私偏好保持权威。
    case notGroup
}

/// 群已读回执的读者候选。
public struct V2GroupReadReceiptReaderCandidate: Equatable, Sendable {
    /// 候选用户。
    public let userID: UserID
    /// 该用户已读到的房间序号。
    public let readThroughRoomSequence: UInt64

    /// 保存读者候选。
    ///
    /// - Parameters:
    ///   - userID: 候选用户。
    ///   - readThroughRoomSequence: 已读到的房间序号。
    public init(userID: UserID, readThroughRoomSequence: UInt64) {
        self.userID = userID
        self.readThroughRoomSequence = readThroughRoomSequence
    }
}

/// 群已读回执读者候选分页。
public struct V2GroupReadReceiptReaderCandidatePage: Equatable, Sendable {
    /// 目标房间。
    public let roomID: RoomID
    /// 目标消息。
    public let messageID: MessageID
    /// 本页候选。
    public let candidates: [V2GroupReadReceiptReaderCandidate]
    /// 下一页游标；为空表示已到末尾。
    public let nextCursor: String?

    /// 保存候选分页。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - messageID: 目标消息。
    ///   - candidates: 本页候选。
    ///   - nextCursor: 下一页游标。
    public init(
        roomID: RoomID,
        messageID: MessageID,
        candidates: [V2GroupReadReceiptReaderCandidate],
        nextCursor: String?
    ) {
        self.roomID = roomID
        self.messageID = messageID
        self.candidates = candidates
        self.nextCursor = nextCursor
    }
}

/// 房间本地的读者候选能力。
///
/// 候选结果不包含全局身份信息，也不包含隐私判定，披露与否由用户维度决定。
public protocol V2GroupReadReceiptReaderCandidateStore: Sendable {
    /// 分页读取房间本地的读者候选。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - messageID: 目标消息。
    ///   - actorUserID: 发起查询的用户。
    ///   - cursor: 上一页游标。
    ///   - pageSize: 本页条数。
    /// - Returns: 候选分页。
    /// - Throws: 无资格或持久化失败时抛出。
    func readerCandidates(
        roomID: RoomID,
        messageID: MessageID,
        actorUserID: UserID,
        cursor: String?,
        pageSize: Int
    ) async throws -> V2GroupReadReceiptReaderCandidatePage
}

/// 在权威的用户与控制面数据库上解析身份披露。
///
/// 缺失、已停用、未生效或选择不披露的用户会被省略，而不是用默认值补齐。
public protocol V2ReadReceiptReaderVisibilityStore: Sendable {
    /// 过滤出可对发起者披露身份的候选用户。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起查询的用户。
    ///   - candidateUserIDs: 候选用户列表。
    /// - Returns: 可披露候选到公开身份的映射。
    /// - Throws: 持久化失败时抛出。
    func visibleReaderIdentities(
        actorUserID: UserID,
        candidateUserIDs: [UserID]
    ) async throws -> [UserID: V2PublicIdentity]
}

/// 房间归属侧的群已读回执存储组合能力。
public protocol V2GroupReadReceiptOwnerStore:
    V2GroupReadReceiptBatchRecordingStore,
    V2GroupReadReceiptReaderCandidateStore {}

/// 控制面侧的已读回执存储组合能力。
public protocol V2ReadReceiptControlStore:
    V2ReadReceiptStore,
    V2ReadReceiptReaderVisibilityStore {}

/// 已读回执的对外服务。
public struct V2ReadReceiptService: Sendable {
    private let store: any V2ReadReceiptStore
    private let batcher: (any V2ReadReceiptAdmission)?
    private let now: @Sendable () -> Date

    /// 是否接管前台写入准入。
    var managesForegroundWriteAdmission: Bool {
        batcher?.managesForegroundWriteAdmission ?? false
    }

    /// 组合回执存储与可选的批量准入器。
    ///
    /// - Parameters:
    ///   - store: 直接执行记录与查询的存储。
    ///   - batcher: 可选的批量准入器；提供时记录路径优先走批量。
    ///   - now: 可注入的当前时刻读取函数。
    public init(
        store: any V2ReadReceiptStore,
        batcher: (any V2ReadReceiptAdmission)? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.batcher = batcher
        self.now = now
    }
    /// 记录一条已读回执。
    ///
    /// 时刻在进入本方法时捕获并随命令一同进入批量器，保证批量延迟不改变生效时刻。
    ///
    /// - Parameter request: 已认证的已读回执请求。
    /// - Returns: 记录结果。
    /// - Throws: 命令构造失败，或批量器与存储抛出错误时抛出。
    public func record(_ request: V2AuthenticatedReadReceipt) async throws -> V2ReadReceiptOutcome {
        let prepared = V2ReadReceiptRecordRequest(
            command: try .init(
                roomID: request.roomID,
                actorUserID: request.actorUserID,
                operationID: request.operationID,
                readThroughRoomSequence: request.readThroughRoomSequence
            ),
            now: now()
        )
        if let batcher { return try await batcher.accept(prepared) }
        return try await store.record(
            command: prepared.command,
            now: prepared.now
        )
    }

    /// 设置已读回执偏好。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起设置的用户。
    ///   - operationID: 幂等操作标识。
    ///   - allowsDirectReadReceipts: 是否允许私聊回执。
    ///   - allowsGroupReadReceipts: 是否允许群回执。
    /// - Returns: 变更结果。
    /// - Throws: 命令构造失败或存储失败时抛出。
    public func setPreferences(actorUserID: UserID, operationID: ReadReceiptPreferenceOperationID, allowsDirectReadReceipts: Bool, allowsGroupReadReceipts: Bool) async throws -> V2SetReadReceiptPreferencesOutcome {
        try await store.setPreferences(command: .init(actorUserID: actorUserID, operationID: operationID, allowsDirectReadReceipts: allowsDirectReadReceipts, allowsGroupReadReceipts: allowsGroupReadReceipts), now: now())
    }

    /// 分页读取读者列表。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - messageID: 目标消息。
    ///   - actorUserID: 发起查询的用户。
    ///   - cursor: 上一页游标。
    ///   - pageSize: 本页条数。
    /// - Returns: 读者分页。
    /// - Throws: 存储实现抛出的错误。
    public func readers(roomID: RoomID, messageID: MessageID, actorUserID: UserID, cursor: String?, pageSize: Int) async throws -> V2ReadReceiptReadersPage {
        try await store.readers(roomID: roomID, messageID: messageID, actorUserID: actorUserID, cursor: cursor, pageSize: pageSize)
    }
}

/// 已读回执存储错误。
public enum V2ReadReceiptStoreError: Error, Equatable, Sendable {
    /// 房间归属已变更。
    case ownerChanged
    /// 房间不存在。
    case roomNotFound
    /// 消息不存在。
    case messageNotFound
    /// 发起者不是房间成员。
    case actorNotMember
    /// 指定的房间序号不存在。
    case roomSequenceNotFound
    /// 请求参数不满足约束。
    case invalidRequest
    /// 持久化记录缺失或字段无法解码。
    case corruptPersistenceState
}
