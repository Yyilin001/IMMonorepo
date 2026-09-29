import IMV2ServerContracts
import Foundation
import IMV2Core

/// 已读回执的对外服务。
public struct V2ReadReceiptService: Sendable {
    private let store: any V2ReadReceiptStore
    private let batcher: (any V2ReadReceiptAdmission)?
    private let now: @Sendable () -> Date

    /// 是否接管前台写入准入。
    package var managesForegroundWriteAdmission: Bool {
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
