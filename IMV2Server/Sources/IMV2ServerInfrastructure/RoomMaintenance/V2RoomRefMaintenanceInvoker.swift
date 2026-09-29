import IMV2ServerApplication
import IMV2ServerContracts
import IMV2ActorContracts
import IMV2ActorRuntime

/// 工作器扫描只提供提示；每次修改都凭服务明确配置的维护权限
/// 获取新的逻辑房间轮次。
public struct V2RoomRefMaintenanceInvoker: V2RoomMaintenanceInvoking {
    private let directory: V2RoomDirectory

    public init(directory: V2RoomDirectory) { self.directory = directory }

    public func invoke(_ command: V2RoomMaintenanceCommand,
                       deadline: ContinuousClock.Instant) async throws -> V2RoomMaintenanceResult {
        let response = try await directory.room(command.roomID).call(.maintenance(command),
            principal: .service, deadline: deadline)
        guard case .maintenance(let result) = response else { throw V2RoomCallFailure.outcomeUnknown }
        return result
    }
}
