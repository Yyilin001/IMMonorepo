import Foundation

/// 置顶状态投影事件。
///
/// 置顶顺序来自来源房间日志：对历史载荷而言，接收端游标与墙上时钟时间戳都无法还原该顺序，
/// 因此比较时以房间序号为准。
struct V2PinnedMessageSnapshotEffect: Equatable {
    /// 目标房间。
    let roomID: UUID
    /// 被置顶或取消置顶的消息。
    let messageID: UUID
    /// 变更后的置顶状态。
    let isPinned: Bool
    /// 来源房间日志序号；历史载荷可能缺失。
    let roomSequence: Int64?
    /// 发起置顶变更的用户；历史载荷可能缺失。
    let actorID: UUID?
    /// 服务端事件时间戳（毫秒）。
    let updatedAtMilliseconds: Int64

    /// 投影实体键，由房间与消息标识唯一确定。
    var entityKey: String { "pin:\(roomID.uuidString):\(messageID.uuidString)" }

    /// 从事件载荷解码置顶变更。
    ///
    /// - Parameter payload: 事件载荷 JSON。
    /// - Throws: 载荷无法解码、事件类型不符、房间序号非正或时间戳为负时抛出
    ///   ``V2UserProjectionWorkerError/invalidPayload``。
    init(payload: Data) throws {
        struct Wire: Decodable {
            let event_type: String
            let room_id: UUID
            let message_id: UUID
            let is_pinned: Bool
            let room_sequence: Int64?
            let actor_user_id: UUID?
            let server_created_at_ms: Int64
        }
        do {
            let wire = try JSONDecoder().decode(Wire.self, from: payload)
            guard wire.event_type == "message.pinned_changed",
                  wire.room_sequence.map({ $0 > 0 }) ?? true,
                  wire.server_created_at_ms >= 0
            else { throw V2UserProjectionWorkerError.invalidPayload }
            roomID = wire.room_id
            messageID = wire.message_id
            isPinned = wire.is_pinned
            roomSequence = wire.room_sequence
            actorID = wire.actor_user_id
            updatedAtMilliseconds = wire.server_created_at_ms
        } catch { throw V2UserProjectionWorkerError.invalidPayload }
    }

    /// 判断本次观测是否应替换已有投影。
    ///
    /// 同一来源事件必须完全一致，否则视为载荷损坏；唯一例外是本次观测补齐了此前缺失的
    /// 房间序号，此时允许替换以保留已知的来源栅栏。来自不同来源事件时按房间序号决定先后：
    /// 两者都有序号则序号更大者胜出，只有旧值有序号则保留旧值，缺失序号则按兼容语义接受新值。
    ///
    /// - Parameters:
    ///   - prior: 已有投影。
    ///   - sourceEventID: 本次观测的来源事件标识。
    ///   - priorSourceEventID: 已有投影的来源事件标识。
    /// - Returns: 应替换已有投影时为 `true`。
    /// - Throws: 房间或消息不一致、同一事件内容不一致、或两个不同事件给出相同序号时抛出
    ///   ``V2UserProjectionWorkerError/invalidPayload``。
    func shouldReplace(_ prior: Self, sourceEventID: UUID, priorSourceEventID: UUID) throws -> Bool {
        guard roomID == prior.roomID, messageID == prior.messageID else {
            throw V2UserProjectionWorkerError.invalidPayload
        }
        if sourceEventID == priorSourceEventID {
            guard isPinned == prior.isPinned, actorID == prior.actorID,
                  updatedAtMilliseconds == prior.updatedAtMilliseconds,
                  roomSequence == nil || prior.roomSequence == nil || roomSequence == prior.roomSequence
            else { throw V2UserProjectionWorkerError.invalidPayload }
            // A later observation may supply missing source metadata. Never
            // drop a known source fence when replaying an older encoding.
            return prior.roomSequence == nil && roomSequence != nil
        }
        switch (prior.roomSequence, roomSequence) {
        case let (.some(old), .some(new)):
            guard old != new else { throw V2UserProjectionWorkerError.invalidPayload }
            return new > old
        case (.some, .none): return false
        case (.none, .some): return true
        case (.none, .none):
            // Compatibility with pre-source-version writers. This preserves
            // their observations, including unpin, but does not reconstruct
            // legacy order. Recovery/cutover must resolve that separately.
            return true
        }
    }
}
