import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2Core

/// 批量已读回执中的单条请求及其专属房间归属。
///
/// 即使一个批次共享同一物理归属，每一行也保留自己的路由，避免跨逻辑分片复用归属。
public struct V2OwnerValidatedReadReceiptRequest: Sendable {
    /// 需要记录的单条已读回执请求。
    public let request: V2ReadReceiptRecordRequest
    /// 该请求所属房间的已选定归属。
    public let ownerRoute: V2RoomShardRoute

    /// 组合单条请求与其房间归属。
    ///
    /// - Parameters:
    ///   - request: 需要记录的单条已读回执请求。
    ///   - ownerRoute: 该请求所属房间的已选定归属。
    public init(request: V2ReadReceiptRecordRequest, ownerRoute: V2RoomShardRoute) {
        self.request = request; self.ownerRoute = ownerRoute
    }
}

/// 带房间归属的已读回执写入与查询能力。
public protocol V2OwnerValidatedReadReceiptStore: Sendable {
    /// 在源事务中校验所有者，同时记录对应的房间类别。
    func recordOwnerValidated(command: V2RecordReadReceiptCommand, ownerRoute: V2RoomShardRoute, now: Date) async throws -> V2ReadReceiptOutcome

    /// 按房间归属记录一次群已读回执。
    ///
    /// - Parameters:
    ///   - command: 已读回执命令。
    ///   - ownerRoute: 已选定的房间归属，事务内据此校验归属。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 本次记录尝试的结果。
    /// - Throws: 归属已变更、权限不足或持久化失败时抛出。
    func recordGroupOwnerValidated(command: V2RecordReadReceiptCommand, ownerRoute: V2RoomShardRoute, now: Date) async throws -> V2GroupReadReceiptRecordingAttempt

    /// 按各自归属批量记录多个房间的已读回执。
    ///
    /// - Parameter requests: 逐条携带归属的请求批次。
    /// - Returns: 与输入顺序对应的逐条结果。
    /// - Throws: 任一条目的归属校验失败或持久化失败时抛出。
    func recordGroupsOwnerValidated(_ requests: [V2OwnerValidatedReadReceiptRequest]) async throws -> [V2GroupReadReceiptBatchResult]

    /// 按房间归属分页读取某条消息的读者候选。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - messageID: 需要读取回执的消息。
    ///   - actorUserID: 发起查询的用户，需具备读取资格。
    ///   - ownerRoute: 已选定的房间归属。
    ///   - cursor: 上一页游标；为空表示从头开始。
    ///   - pageSize: 本页最大条数。
    /// - Returns: 读者候选分页。
    /// - Throws: 归属已变更、权限不足或持久化失败时抛出。
    func readerCandidatesOwnerValidated(roomID: RoomID, messageID: MessageID, actorUserID: UserID, ownerRoute: V2RoomShardRoute, cursor: String?, pageSize: Int) async throws -> V2GroupReadReceiptReaderCandidatePage
}
