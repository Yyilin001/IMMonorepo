import Foundation
import IMV2Core

/// 会话摘要游标的线格式。
///
/// 只承载分页排序键 `(last_event_at, room_id)`，因此不需要房间修订或授权信息：
/// 每一页都会重新按当前成员资格过滤，伪造游标既不能越权，也不能改变可见集合。
struct V2RoomSummaryCursorPayload: Codable, Equatable {
    /// 格式版本；用于拒绝猜测式解析。
    let version: Int
    /// 上一行的事件时间，自 1970 年起的微秒数。
    let lastEventAtMicroseconds: Int64
    /// 上一行的房间标识。
    let roomID: String
}

/// 会话摘要游标的不透明编码。
///
/// 客户端只回传字符串，不得解析、拼接或跨设备复用。解析失败一律按非法参数处理，
/// 不做兼容猜测：一个被误读的游标会让房间从列表里静默消失，比显式报错危险得多。
enum V2RoomSummaryCursorCodec {
    /// 当前格式版本。
    static let currentVersion = 1
    /// 允许的最大 UTF-8 字节数。
    static let maximumBytes = 512

    /// 把游标编码成不透明字符串。
    ///
    /// - Parameter cursor: 分页排序键。
    /// - Returns: base64 编码的载荷。
    /// - Throws: 载荷无法编码时抛出 ``V2RoomSummaryError/corruptPersistenceState``。
    static func encode(_ cursor: V2RoomSummaryCursor) throws -> String {
        let payload = V2RoomSummaryCursorPayload(
            version: currentVersion,
            lastEventAtMicroseconds: cursor.lastEventAtMicroseconds,
            roomID: cursor.roomID.rawValue
        )
        guard let data = try? JSONEncoder().encode(payload) else {
            throw V2RoomSummaryError.corruptPersistenceState
        }
        return data.base64EncodedString()
    }

    /// 解析客户端回传的游标。
    ///
    /// - Parameter raw: 客户端原样回传的字符串。
    /// - Returns: 分页排序键。
    /// - Throws: 空串、超长、非法 base64、版本不符、微秒为负或房间标识非法时抛出
    ///   ``V2RoomSummaryError/invalidRequest``。
    static func decode(_ raw: String) throws -> V2RoomSummaryCursor {
        guard !raw.isEmpty, raw.utf8.count <= maximumBytes,
              let data = Data(base64Encoded: raw),
              let payload = try? JSONDecoder().decode(V2RoomSummaryCursorPayload.self, from: data),
              payload.version == currentVersion,
              payload.lastEventAtMicroseconds >= 0,
              let roomID = try? RoomID(payload.roomID)
        else { throw V2RoomSummaryError.invalidRequest }
        return V2RoomSummaryCursor(
            lastEventAtMicroseconds: payload.lastEventAtMicroseconds,
            roomID: roomID
        )
    }
}
