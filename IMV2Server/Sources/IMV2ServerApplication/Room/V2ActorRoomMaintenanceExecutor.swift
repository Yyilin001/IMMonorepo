import IMV2ServerContracts
import Foundation
import IMV2ActorContracts
import IMV2Core

/// 仅在宿主批准维护房间轮次后运行。
/// 扫描器的观测不能作为写入物理所有者数据库的权限依据。
public struct V2ActorRoomMaintenanceExecutor: Sendable {
    private let persistence: any V2RoomMaintenancePersisting
    private let now: @Sendable () -> Date

    package init(persistence: any V2RoomMaintenancePersisting,
                 now: @escaping @Sendable () -> Date = Date.init) {
        self.persistence = persistence
        self.now = now
    }

    public func execute(_ command: V2RoomMaintenanceCommand,
                        token: V2RoomActivationToken) async throws -> V2RoomMaintenanceResult {
        guard command.roomID == token.roomID else { throw V2RoomActivationLeaseError.activationChanged }
        return try await persistence.execute(command, token: token, now: now())
    }
}
