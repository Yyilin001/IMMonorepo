import Foundation
import IMV2Core

/// 已获授权的完整编辑结果值。
///
/// 变更顺序仍由所属房间事件决定；本值只保留不可变的接受身份，
/// 以便重放和投影校验能追溯到原始接受事件。
struct V2MessageEditReplacement: Codable, Equatable, Sendable {
    /// 载荷结构版本，当前为 1。
    let schemaVersion: Int
    /// 原始接受事件标识。
    let acceptedEventID: UUID
    /// 原始接受时的成员修订。
    let acceptedMembershipRevision: Int64
    /// 编辑后的消息投影状态。
    let state: V2MessageProjectionState

    /// 以编辑后的投影状态与原始接受凭据构造替换值。
    ///
    /// - Parameters:
    ///   - state: 编辑后的投影状态。
    ///   - delivery: 原始接受凭据，用于冻结接受身份。
    /// - Throws: 修订号不大于 1、消息已撤回、房间序号与接受凭据不符，
    ///   或成员修订为负时抛出 ``V2MessageProjectionStateError/invalidPayload``。
    init(state: V2MessageProjectionState, delivery: V2MessageAcceptedDelivery) throws {
        guard state.messageRevision > 1, !state.isWithdrawn,
              state.acceptedRoomSequence == delivery.roomSequence,
              delivery.membershipRevision >= 0
        else { throw V2MessageProjectionStateError.invalidPayload }
        schemaVersion = 1
        acceptedEventID = delivery.eventID
        acceptedMembershipRevision = delivery.membershipRevision
        self.state = state
    }

    /// 以键序稳定且不转义斜杠的 JSON 编码输出替换值。
    ///
    /// - Returns: UTF-8 JSON 字符串。
    /// - Throws: 编码失败时抛出。
    func encodedJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    /// 从投影对象中解码可选的替换值。
    ///
    /// 字段存在即为权威：一旦出现 `replacement` 则必须是合法替换值，
    /// 格式错误不得退化为增量合并，以免丢失被编辑过的正文。
    ///
    /// - Parameter object: 包含或不包含 `replacement` 的投影对象。
    /// - Returns: 解码后的替换值；字段缺失时返回 `nil`。
    /// - Throws: 结构版本不符、成员修订为负、状态已撤回或修订不大于 1、
    ///   消息与房间标识不匹配、头部修订与状态不一致、房间序号未严格递增、
    ///   正文或实体不一致时抛出 ``V2MessageProjectionStateError/invalidPayload``。
    static func decodeIfPresent(in object: [String: Any]) throws -> Self? {
        guard let raw = object["replacement"] else { return nil }
        do {
            struct Header: Decodable {
                let message_id: String; let room_id: String; let message_revision: UInt64
                let room_sequence: UInt64; let text: String; let entities: [V2MessageEntity]
            }
            let decoder = JSONDecoder()
            let header = try decoder.decode(Header.self, from: JSONSerialization.data(withJSONObject: object))
            let value = try decoder.decode(Self.self, from: JSONSerialization.data(withJSONObject: raw, options: [.fragmentsAllowed]))
            guard value.schemaVersion == 1, value.acceptedMembershipRevision >= 0,
                  !value.state.isWithdrawn, value.state.messageRevision > 1,
                  value.state.messageID == (try MessageID(header.message_id)),
                  value.state.roomID == (try RoomID(header.room_id)),
                  header.message_revision == value.state.messageRevision,
                  header.room_sequence > value.state.acceptedRoomSequence,
                  header.text == value.state.text, header.entities == value.state.entities
            else { throw V2MessageProjectionStateError.invalidPayload }
            return value
        } catch { throw V2MessageProjectionStateError.invalidPayload }
    }

    /// 从解码器读取替换值并校验必需字段。
    ///
    /// - Parameter decoder: 数据解码器。
    /// - Throws: 必需引用字段缺失或投影状态无法解码时抛出
    ///   ``V2MessageProjectionStateError/invalidPayload``。
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        acceptedEventID = try c.decode(UUID.self, forKey: .acceptedEventID)
        acceptedMembershipRevision = try c.decode(Int64.self, forKey: .acceptedMembershipRevision)
        let stateDecoder = try c.superDecoder(forKey: .state)
        enum ReferenceKeys: String, CodingKey, CaseIterable {
            case reply_to_message_id, forwarded_from_message_id, forwarded_from_user_id
        }
        let fields = try stateDecoder.container(keyedBy: ReferenceKeys.self)
        guard ReferenceKeys.allCases.allSatisfy(fields.contains) else { throw V2MessageProjectionStateError.invalidPayload }
        state = try V2MessageProjectionState(from: stateDecoder)
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", acceptedEventID = "accepted_event_id"
        case acceptedMembershipRevision = "accepted_membership_revision", state
    }
}
