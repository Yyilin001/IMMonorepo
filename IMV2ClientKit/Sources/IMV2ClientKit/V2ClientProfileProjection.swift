import Foundation
import IMV2Core

/// 资料失效通知。
///
/// 它是持久化的投递元数据而非资料内容本身；仓储据此在同步事务提交后合并已授权的批量读取。
struct V2ClientProfileInvalidation: Equatable, Sendable {
    /// 资料发生变化的用户。
    let userID: UserID
    /// 触发本次失效的最小资料修订。
    let minimumRevision: V2ProfileRevision
    /// 用户当前资料状态。
    let state: V2ProfileState

    /// 从同步记录解码资料失效通知。
    ///
    /// - Parameter record: 投影类型为资料失效的同步记录。
    /// - Throws: 投影类型不符、载荷无法解码、修订或状态取值未知、用户标识非法时抛出
    ///   ``V2ClientProjectionError/invalidMessagePayload``。
    init(record: V2ClientSyncRecord) throws {
        struct Wire: Decodable {
            let userID: String
            let minimumRevision: UInt64
            let profileState: String?
            enum CodingKeys: String, CodingKey {
                case userID = "user_id"
                case minimumRevision = "minimum_profile_revision"
                case profileState = "profile_state"
            }
        }
        guard record.projectionKind == "profile_invalidation",
              let wire = try? JSONDecoder().decode(Wire.self, from: record.payload),
              let revision = V2ProfileRevision(rawValue: wire.minimumRevision),
              let state = V2ProfileState(rawValue: wire.profileState ?? V2ProfileState.active.rawValue)
        else { throw V2ClientProjectionError.invalidMessagePayload }
        do {
            userID = try .init(wire.userID)
            minimumRevision = revision
            self.state = state
        } catch {
            throw V2ClientProjectionError.invalidMessagePayload
        }
    }
}
