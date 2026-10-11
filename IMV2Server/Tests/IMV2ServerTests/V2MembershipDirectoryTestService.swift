// Test-only adapter; production requests use RoomRef clients.
@testable import IMV2ServerContracts
import Foundation
import IMV2Core

/// 成员名录服务。
///
/// 校验与授权留在窄接口之后，便于独立测试。网关适配器只能传入已认证的发起者身份，
/// 不会拿到无界名册。
struct V2MembershipDirectoryTestService: V2GatewayRoomMembershipDirectoryHandling {
    private let store: any V2RoomMembershipDirectoryStore

    /// 组合名录存储。
    ///
    /// - Parameter store: 实际执行读取的存储实现。
    init(store: any V2RoomMembershipDirectoryStore) {
        self.store = store
    }

    /// 读取一页成员名录。
    ///
    /// 返回的成员修订必须能写入有符号 64 位范围，否则视为持久化状态损坏。
    ///
    /// - Parameter request: 已校验的查询请求。
    /// - Returns: 成员名录分页。
    /// - Throws: 成员修订超出可编码范围时抛出
    ///   ``V2RoomMembershipDirectoryError/corruptPersistenceState``；其余错误来自存储实现。
    func list(_ request: V2RoomMembershipDirectoryRequest) async throws -> V2RoomMembershipDirectoryPage {
        let page = try await store.list(request)
        guard page.membershipRevision <= UInt64(Int64.max) else {
            throw V2RoomMembershipDirectoryError.corruptPersistenceState
        }
        return page
    }
}
