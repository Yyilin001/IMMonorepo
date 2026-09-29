import IMV2ServerContracts
import Foundation
import IMV2Core

/// 本地转发能力，要求同时给出源房间与目标房间的归属，同物理分片也不例外。
public protocol V2OwnerValidatedForwardMessagesHandling: V2ForwardMessagesHandling {
    /// 按源房间与目标房间的归属执行转发。
    ///
    /// - Parameters:
    ///   - actorUserID: 发起转发的用户。
    ///   - command: 转发命令。
    ///   - ownerRoutes: 本次涉及的全部房间归属，键为房间标识。
    /// - Returns: 与目标房间对应的转发结果。
    /// - Throws: 缺少任一房间的归属、归属已变更或持久化失败时抛出。
    func forwardOwnerValidated(actorUserID: UserID, command: V2ForwardMessagesCommand,
        ownerRoutes: [RoomID: V2RoomShardRoute]) async throws -> [V2ForwardMessageResult]
}

/// 按归属执行转发写入的房间写存储能力。
public protocol V2OwnerValidatedForwardMessageWriteStore: V2RoomWriteStore {
    /// 在源房间与目标房间的归属均已校验的前提下接受一条转发消息。
    ///
    /// - Parameters:
    ///   - request: 目标房间的写入请求。
    ///   - sourceRoomID: 转发来源房间。
    ///   - sourceOwnerRoute: 来源房间的已选定归属。
    ///   - targetOwnerRoute: 目标房间的已选定归属。
    /// - Returns: 目标房间的发送结果。
    /// - Throws: 任一归属已变更、来源授权失效或持久化失败时抛出。
    func acceptForwardOwnerValidated(request: V2RoomWriteRequest, sourceRoomID: RoomID,
        sourceOwnerRoute: V2RoomShardRoute, targetOwnerRoute: V2RoomShardRoute) async throws -> V2SendMessageOutcome
}
