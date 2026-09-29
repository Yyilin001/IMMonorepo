import IMV2ServerContracts
import IMV2Core

extension V2GroupEventLogService {
    /// 在支持预编码的存储上拉取可直接回传的分页。
    ///
    /// 存储不支持预编码时退化为普通拉取；返回预编码结果时会额外校验下一页序号与
    /// 「是否还有后续」标记的一致性。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - actorUserID: 发起拉取的用户。
    ///   - afterRoomSequence: 起始序号。
    ///   - pageSize: 本页最多返回的事件数。
    ///   - context: 帧与压缩协商上下文，帧版本需不低于 21。
    /// - Returns: 预编码拉取结果。
    /// - Throws: 参数越界时抛出 ``V2GroupEventLogError/invalidRequest``；
    ///   返回分页序号异常时抛出 ``V2GroupEventLogError/corruptPersistenceState``。
    package func pullPrepared(
        roomID: RoomID,
        actorUserID: UserID,
        afterRoomSequence: UInt64,
        pageSize: Int,
        context: V2PreparedGroupEventPageEncodingContext
    ) async throws -> V2PreparedGroupEventPullResult {
        guard (try? V2RoomCursor(afterRoomSequence)) != nil,
              pageSize > 0,
              pageSize <= Self.maximumPageSize,
              context.frameVersion >= 21
        else { throw V2GroupEventLogError.invalidRequest }
        guard let preparedStore = store as? any V2PreparedGroupEventLogStore else {
            return .page(try validatePage(await store.pull(
                roomID: roomID,
                actorUserID: actorUserID,
                afterRoomSequence: afterRoomSequence,
                pageSize: pageSize
            ), after: afterRoomSequence))
        }
        let result = try await preparedStore.pullPrepared(
            roomID: roomID,
            actorUserID: actorUserID,
            afterRoomSequence: afterRoomSequence,
            pageSize: pageSize,
            context: context
        )
        if case .page(let page) = result { return .page(try validatePage(page, after: afterRoomSequence)) }
        if case .prepared(let response) = result {
            guard response.nextRoomSequence <= UInt64(Int64.max),
                  response.nextRoomSequence >= afterRoomSequence,
                  !response.hasMore || response.nextRoomSequence > afterRoomSequence
            else { throw V2GroupEventLogError.corruptPersistenceState }
        }
        return result
    }
}
